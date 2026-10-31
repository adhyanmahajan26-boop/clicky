//
//  GroundingModels.swift
//  ClickyCore
//
//  The things Clicky can point at: accessibility elements and OCR text,
//  merged into one numbered registry per question. Every frame is in CG
//  global points.
//

import CoreGraphics
import Foundation

/// Short role names used in the element list.
public enum GroundingRole: String, Sendable, CaseIterable {
    case button = "btn"
    case link
    case textField = "tf"
    case textArea = "ta"
    case checkBox = "chk"
    case radio
    case tab
    case popUp = "pop"
    case menu
    case menuItem = "mi"
    case slider = "sld"
    case image = "img"
    case text = "txt"
    case cell
    case row
    case dock
    case window = "win"
}

public enum GroundingSource: String, Sendable {
    case accessibility
    case ocr
}

/// An opaque handle to a live AX element (or a mock's node), so an element
/// can be refreshed and hit-tested later.
public final class AXNodeReference: @unchecked Sendable, Hashable {
    public let underlyingObject: AnyObject

    public init(_ underlyingObject: AnyObject) {
        self.underlyingObject = underlyingObject
    }

    public static func == (lhs: AXNodeReference, rhs: AXNodeReference) -> Bool {
        lhs.underlyingObject === rhs.underlyingObject
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(underlyingObject))
    }
}

public struct GroundingElement: Sendable, Equatable {
    public var role: GroundingRole
    public var label: String?
    public var value: String?
    /// The element's full frame.
    public var frameCG: CGRect
    /// The part not clipped by scroll views, windows etc.
    public var visibleFrameCG: CGRect
    public var processIdentifier: pid_t
    public var windowID: CGWindowID?
    public var windowTitle: String?
    public var applicationName: String?
    public var displayID: CGDirectDisplayID
    public var isInteractive: Bool
    public var isEnabled: Bool
    public var isFocused: Bool
    public var isInFrontWindow: Bool
    /// Covered by another app's window: listed, never badged.
    public var isBehind: Bool
    /// Menu bar, Dock and open menus are never "behind".
    public var isSystemChrome: Bool
    public var source: GroundingSource
    /// Front-to-back position of its window (0 = frontmost).
    public var windowZIndex: Int
    public var axNode: AXNodeReference?

    public init(role: GroundingRole, label: String?, value: String? = nil, frameCG: CGRect, visibleFrameCG: CGRect? = nil,
                processIdentifier: pid_t, windowID: CGWindowID? = nil, windowTitle: String? = nil, applicationName: String? = nil,
                displayID: CGDirectDisplayID, isInteractive: Bool, isEnabled: Bool = true, isFocused: Bool = false,
                isInFrontWindow: Bool = false, isBehind: Bool = false, isSystemChrome: Bool = false,
                source: GroundingSource, windowZIndex: Int = 0, axNode: AXNodeReference? = nil) {
        self.role = role
        self.label = label
        self.value = value
        self.frameCG = frameCG
        self.visibleFrameCG = visibleFrameCG ?? frameCG
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.windowTitle = windowTitle
        self.applicationName = applicationName
        self.displayID = displayID
        self.isInteractive = isInteractive
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.isInFrontWindow = isInFrontWindow
        self.isBehind = isBehind
        self.isSystemChrome = isSystemChrome
        self.source = source
        self.windowZIndex = windowZIndex
        self.axNode = axNode
    }

    public static func == (lhs: GroundingElement, rhs: GroundingElement) -> Bool {
        lhs.role == rhs.role && lhs.label == rhs.label && lhs.value == rhs.value && lhs.frameCG == rhs.frameCG
            && lhs.processIdentifier == rhs.processIdentifier && lhs.source == rhs.source && lhs.isBehind == rhs.isBehind
    }

    /// Everything a name could match against.
    public var matchableTexts: [String?] { [label, value] }
    public var isOCROnly: Bool { source == .ocr }
}

/// One line of recognised text with its CG frame.
public struct OCRLine: Sendable, Equatable {
    public var text: String
    public var frameCG: CGRect
    public var displayID: CGDirectDisplayID
    public var confidence: Float

    public init(text: String, frameCG: CGRect, displayID: CGDirectDisplayID, confidence: Float = 1) {
        self.text = text
        self.frameCG = frameCG
        self.displayID = displayID
        self.confidence = confidence
    }
}

/// The numbered elements for one question. Ids are stable for that question
/// (and its worker follow-ups) only.
public struct ElementRegistry: Sendable {
    public struct Entry: Sendable {
        public let elementID: Int
        public var element: GroundingElement
        public var isBadged: Bool
    }

    public private(set) var entries: [Int: Entry] = [:]
    public private(set) var orderedIDs: [Int] = []
    /// All OCR lines (the list is trimmed; text lookups search everything).
    public var allOCRLines: [OCRLine] = []

    public init() {}

    public mutating func append(_ element: GroundingElement) -> Int {
        let elementID = orderedIDs.count + 1
        entries[elementID] = Entry(elementID: elementID, element: element, isBadged: false)
        orderedIDs.append(elementID)
        return elementID
    }

    public mutating func setBadged(_ elementID: Int, _ isBadged: Bool) {
        entries[elementID]?.isBadged = isBadged
    }

    public subscript(elementID: Int) -> GroundingElement? {
        entries[elementID]?.element
    }

    public var liveElementIDs: Set<Int> { Set(orderedIDs) }
}

public extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    func intersectionOverUnion(with otherRect: CGRect) -> CGFloat {
        let intersectionArea = intersection(otherRect).area
        let unionArea = area + otherRect.area - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    /// Distance between the edges (0 when overlapping or touching).
    func edgeDistance(to point: CGPoint) -> CGFloat {
        let deltaX = max(minX - point.x, 0, point.x - maxX)
        let deltaY = max(minY - point.y, 0, point.y - maxY)
        return hypot(deltaX, deltaY)
    }
}
