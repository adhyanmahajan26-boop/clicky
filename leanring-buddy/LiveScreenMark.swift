//
//  LiveScreenMark.swift
//  leanring-buddy
//
//  A live mark (ring, box, arrow, underline, spot or numbered step) drawn on
//  top of the user's screen while Clicky answers. Tags are parsed by
//  ClickyCore's MarkTagParser and resolved to real element frames by its
//  TargetResolver; MarkController lays these out (MarkLayout) and
//  MarkTracker keeps AX-backed ones on their element.
//

import ClickyCore
import CoreGraphics
import Foundation

/// Where a mark's rect came from, which decides how it can be followed.
enum LiveScreenMarkSource: String {
    /// An AX element: tracked as it scrolls or moves.
    case accessibility
    /// OCR text: re-checked once, cleared when its window scrolls or moves.
    case ocr
    /// A model coordinate snapped to a nearby element.
    case snapped
    /// A bare model coordinate.
    case raw
}

struct LiveScreenMark: Identifiable {
    let id = UUID()
    let style: MarkStyleKind
    /// The target in CG global points (main display top-left, y down).
    var rectCG: CGRect
    /// The note, else the name for arrow and step marks, else nil.
    let displayText: String?
    let source: LiveScreenMarkSource
    /// The element, for tracking (AX marks only).
    let ax: AXNodeReference?
    var confidence: Double
    /// Drawn dashed and faded: low confidence, occluded, or failed its re-check.
    var isTentative: Bool
    let createdAt: Date
    /// The topmost app window at the mark's centre when it was made.
    var windowID: CGWindowID?
    var windowFrameCG: CGRect?
    /// Nearest scroll/web area above the element (the mark hides when scrolled out).
    var clipAX: AXNodeReference?
    /// The element whose text named it (self or a static text child).
    var labelAX: AXNodeReference?
    var originalLabel: String?
    /// The text the OCR re-check looks for (OCR / snapped / raw marks with a name).
    let recheckName: String?
    /// Position in the answer (draw-on stagger, step order).
    let order: Int
    /// Index of its tag in turn.json, for the `drawn` record.
    let tagIndex: Int?
    var isHidden = false
    var opacity = 1.0
    /// Text / control / unknown, from the element's role (decides underline vs ring on dense UI).
    var targetRole: MarkTargetRole = .unknown
    /// Where the target was when first drawn: MarkController shifts the
    /// answer's text obstacles by how far a tracked mark has since moved.
    var originalRectCG: CGRect?

    static let tentativeConfidence = 0.7

    var sceneInput: MarkSceneInput {
        MarkSceneInput(id: id, style: style, rectCG: rectCG, displayText: displayText, isTentative: isTentative,
                       isHidden: isHidden, opacity: opacity, order: order, windowFrameCG: windowFrameCG, targetRole: targetRole)
    }

    static func source(for target: ResolvedTarget) -> LiveScreenMarkSource {
        switch target.method {
        case .snapped: return .snapped
        case .raw: return .raw
        default: return target.axNode != nil ? .accessibility : .ocr
        }
    }

    static func style(for markStyle: MarkStyle?) -> MarkStyleKind {
        switch markStyle {
        case .box?: return .box
        case .arrow?: return .arrow
        case .underline?: return .underline
        case .spot?: return .spot
        case .step(let stepNumber)?: return .step(stepNumber)
        default: return .circle
        }
    }
}
