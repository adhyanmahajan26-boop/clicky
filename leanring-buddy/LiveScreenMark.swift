//
//  LiveScreenMark.swift
//  leanring-buddy
//
//  Live marks are circles, boxes, arrows, underlines, spots and numbered
//  step badges drawn on top of the user's screen while Clicky answers. Tags
//  are parsed by ClickyCore's MarkTagParser and resolved to real element
//  frames by its TargetResolver; this is just what the overlay draws.
//

import CoreGraphics
import Foundation

enum LiveScreenMarkKind: Equatable {
    /// A ring around the target.
    case circle
    /// A rectangle around the target.
    case box
    /// An arrow whose head points at the target.
    case arrow
    /// A line under the target (text).
    case underline
    /// A soft dot on the target's centre.
    case spot
    /// A numbered badge for multi-step instructions.
    case numberedStep(stepNumber: Int)
}

/// A mark ready to draw. `frameCG` is the resolved target in CG global
/// points (main display top-left, y down); a raw point has zero size.
struct LiveScreenMark: Identifiable, Equatable {
    let id = UUID()
    let markKind: LiveScreenMarkKind
    let frameCG: CGRect
    /// Text shown next to the mark (the tag's note, or the name for arrows and steps).
    let markLabel: String?
    /// Position in the response, used to stagger the draw-in animation so
    /// marks appear one after another instead of all at once.
    let orderInResponse: Int

    var locationCG: CGPoint { CGPoint(x: frameCG.midX, y: frameCG.midY) }
}
