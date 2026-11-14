//
//  SnapshotTag.swift
//  ClickyCore
//
//  What a [SNAP:…] tag asks for, and the pure math for the part of the screen
//  it covers. The grammar is parsed in MarkTagParser; the capture itself is in
//  the app (leanring-buddy/Capture/SnapshotCapture.swift).
//
//    [SNAP:screen]        the display under the cursor
//    [SNAP:window]        the topmost window of the frontmost app
//    [SNAP:marks]         the area around the marks on screen right now
//    [SNAP:window+marks]  any target, keeping Clicky's own windows (its marks) in the shot
//    [SNAP:board]         save the open whiteboard (PDF + PNG + .clickyboard in
//                         ~/Pictures/Clicky, BoardExportLocation), not a screenshot
//
//  Without "+marks" Clicky's own windows are left out, so the shot is the
//  user's content only.
//

import CoreGraphics
import Foundation

public enum SnapshotTarget: String, Equatable, Sendable, CaseIterable {
    /// The whole display the cursor is on.
    case screen
    /// The topmost window of the frontmost app (never Clicky's own).
    case window
    /// The marked region: the marks' rectangles plus a margin.
    case marks
    /// The open whiteboard, exported (BoardController.exportBoard): "save this as a PDF".
    case board
}

/// Where a saved board goes and what Clicky says after saving it. The folder
/// is the one P6.10 established (the PNG, the PDF and the .clickyboard side by
/// side, the same folder hands-free session captures use).
public enum BoardExportLocation {
    public static func directory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Pictures/Clicky", isDirectory: true)
    }

    /// Spoken after a save (the folder, in words; never the file name).
    public static let savedLine = "saved the board as a PDF and a picture in the Clicky folder in your Pictures."
    public static let failedLine = "I couldn't save the board."
    public static let noBoardLine = "there's no board open to save."
}

public struct SnapshotRequest: Equatable, Sendable {
    public let target: SnapshotTarget
    /// "+marks": keep Clicky's own windows (the overlay with its marks) in the shot.
    public let includesClickyOverlay: Bool

    public init(target: SnapshotTarget, includesClickyOverlay: Bool = false) {
        self.target = target
        self.includesClickyOverlay = includesClickyOverlay
    }
}

public enum SnapshotRegion {
    /// Space kept around the marks, so the labels next to them and the things they sit on are in the shot.
    public static let marksMarginPoints: CGFloat = 24

    /// The marked region: the union of every mark's rectangle, grown by
    /// `marksMarginPoints` on each side. Global CG points. nil when there are no marks.
    public static func marksRegion(markRectsCG: [CGRect]) -> CGRect? {
        let usableRects = markRectsCG.filter { !$0.isNull }
        guard let firstRect = usableRects.first else { return nil }
        let unionRect = usableRects.dropFirst().reduce(firstRect) { $0.union($1) }
        return unionRect.insetBy(dx: -marksMarginPoints, dy: -marksMarginPoints)
    }

    /// The region cut down to one display (a capture can't span two). nil when
    /// the region is off that display entirely.
    public static func clamped(_ region: CGRect, to displayBoundsCG: CGRect) -> CGRect? {
        let visibleRegion = region.intersection(displayBoundsCG)
        guard !visibleRegion.isNull, visibleRegion.width > 0, visibleRegion.height > 0 else { return nil }
        return visibleRegion
    }
}
