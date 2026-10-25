//
//  AXQuerying.swift
//  ClickyCore
//
//  Everything grounding needs from the Accessibility API, behind a protocol
//  so the enumerator, resolver and verifier can be unit-tested with a mock.
//  `SystemAXQuerying` is the real implementation.
//

import ApplicationServices
import CoreGraphics
import Foundation

/// One AX node's basic attributes, read in a single call.
public struct AXNodeAttributes: Sendable, Equatable {
    public var role: String?
    public var subrole: String?
    public var title: String?
    public var elementDescription: String?
    /// AX position + size: CG global points.
    public var frameCG: CGRect?
    public var isEnabled: Bool

    public init(role: String?, subrole: String?, title: String?, elementDescription: String?, frameCG: CGRect?, isEnabled: Bool) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.elementDescription = elementDescription
        self.frameCG = frameCG
        self.isEnabled = isEnabled
    }
}

public protocol AXQuerying: Sendable {
    func isProcessTrusted() -> Bool
    func applicationNode(processIdentifier: pid_t) -> AXNodeReference
    /// role, subrole, title, description, position, size, enabled — one call.
    func attributes(of node: AXNodeReference) -> AXNodeAttributes?
    /// Visible rows for tables/outlines, visible children for lists/browsers,
    /// otherwise the first `limit` children.
    func children(of node: AXNodeReference, role: String?, limit: Int) -> [AXNodeReference]
    func windows(of applicationNode: AXNodeReference) -> [AXNodeReference]
    func menuBar(of applicationNode: AXNodeReference) -> AXNodeReference?
    func stringAttribute(_ attributeName: String, of node: AXNodeReference) -> String?
    func titleUIElementTitle(of node: AXNodeReference) -> String?
    func focusedElement(of applicationNode: AXNodeReference) -> AXNodeReference?
    func isEqual(_ first: AXNodeReference, _ second: AXNodeReference) -> Bool
    func parent(of node: AXNodeReference) -> AXNodeReference?
    func processIdentifier(of node: AXNodeReference) -> pid_t?
    /// App-scoped hit test (CG global point).
    func element(at pointCG: CGPoint, inApplication applicationNode: AXNodeReference) -> AXNodeReference?
    /// System-wide hit test (whatever app is on top there).
    func systemWideElement(at pointCG: CGPoint) -> AXNodeReference?
    /// CG frame of a UTF-16 character range of a text element.
    func boundsForRange(_ range: NSRange, of node: AXNodeReference) -> CGRect?
    func enableManualAccessibility(for applicationNode: AXNodeReference)
}

/// The live Accessibility API.
public final class SystemAXQuerying: AXQuerying, @unchecked Sendable {
    public init(messagingTimeoutSeconds: Float = 0.25) {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeoutSeconds)
    }

    private func element(_ node: AXNodeReference) -> AXUIElement {
        // swiftlint:disable:next force_cast
        node.underlyingObject as! AXUIElement
    }

    private func reference(_ element: AXUIElement) -> AXNodeReference {
        AXNodeReference(element)
    }

    public func isProcessTrusted() -> Bool { AXIsProcessTrusted() }

    public func applicationNode(processIdentifier: pid_t) -> AXNodeReference {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.25)
        return reference(applicationElement)
    }

    public func attributes(of node: AXNodeReference) -> AXNodeAttributes? {
        let attributeNames = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                              kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element(node), attributeNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let valueArray = values as? [AnyObject], valueArray.count == 7,
              CFGetTypeID(valueArray[0]) == CFStringGetTypeID() else {
            // Some implementations (WebKit) don't support the batched read or
            // return error placeholders: read the attributes one by one.
            return attributesReadIndividually(of: node)
        }

        func string(_ index: Int) -> String? { valueArray[index] as? String }
        var frameCG: CGRect?
        if CFGetTypeID(valueArray[4]) == AXValueGetTypeID(), CFGetTypeID(valueArray[5]) == AXValueGetTypeID() {
            var position = CGPoint.zero
            var size = CGSize.zero
            // swiftlint:disable force_cast
            AXValueGetValue(valueArray[4] as! AXValue, .cgPoint, &position)
            AXValueGetValue(valueArray[5] as! AXValue, .cgSize, &size)
            // swiftlint:enable force_cast
            frameCG = CGRect(origin: position, size: size)
        }
        let isEnabled = (valueArray[6] as? Bool) ?? true
        return AXNodeAttributes(role: string(0), subrole: string(1), title: string(2), elementDescription: string(3), frameCG: frameCG, isEnabled: isEnabled)
    }

    private func attributesReadIndividually(of node: AXNodeReference) -> AXNodeAttributes? {
        guard let role = stringAttribute(kAXRoleAttribute, of: node) else { return nil }
        var frameCG: CGRect?
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element(node), kAXPositionAttribute as CFString, &positionValue) == .success,
           AXUIElementCopyAttributeValue(element(node), kAXSizeAttribute as CFString, &sizeValue) == .success,
           let positionValue, let sizeValue,
           CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
            var position = CGPoint.zero
            var size = CGSize.zero
            // swiftlint:disable force_cast
            AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            // swiftlint:enable force_cast
            frameCG = CGRect(origin: position, size: size)
        }
        var enabledValue: CFTypeRef?
        let isEnabled = AXUIElementCopyAttributeValue(element(node), kAXEnabledAttribute as CFString, &enabledValue) == .success
            ? ((enabledValue as? Bool) ?? true) : true
        return AXNodeAttributes(role: role, subrole: stringAttribute(kAXSubroleAttribute, of: node),
                                title: stringAttribute(kAXTitleAttribute, of: node),
                                elementDescription: stringAttribute(kAXDescriptionAttribute, of: node),
                                frameCG: frameCG, isEnabled: isEnabled)
    }

    public func children(of node: AXNodeReference, role: String?, limit: Int) -> [AXNodeReference] {
        let containerElement = element(node)
        let childAttribute: String
        switch role {
        case kAXTableRole, kAXOutlineRole:
            childAttribute = kAXVisibleRowsAttribute
        case kAXListRole, kAXBrowserRole:
            childAttribute = kAXVisibleChildrenAttribute
        default:
            childAttribute = kAXChildrenAttribute
        }
        var childValues: CFArray?
        if childAttribute == kAXChildrenAttribute {
            // The ranged call caps huge child lists, but some implementations
            // (WebKit's web areas) don't support it: fall back to the plain
            // attribute, still capped at `limit`.
            if AXUIElementCopyAttributeValues(containerElement, kAXChildrenAttribute as CFString, 0, limit, &childValues) == .success,
               let rangedChildren = childValues as? [AXUIElement], !rangedChildren.isEmpty {
                return rangedChildren.map(reference)
            }
            var plainValue: CFTypeRef?
            var plainError = AXUIElementCopyAttributeValue(containerElement, kAXChildrenAttribute as CFString, &plainValue)
            // WebKit builds a web view's accessibility tree lazily: the first
            // query of its container answers "no value", a moment later the
            // whole subtree is there. Ordinary empty containers return an
            // empty list instead, so only this error is retried (this runs on
            // the walk's own thread, never the main thread).
            var retryCount = 0
            while plainError == .noValue, retryCount < 4, role == kAXGroupRole || role == kAXScrollAreaRole || role == "AXWebArea" {
                Thread.sleep(forTimeInterval: 0.025)
                plainError = AXUIElementCopyAttributeValue(containerElement, kAXChildrenAttribute as CFString, &plainValue)
                retryCount += 1
            }
            guard plainError == .success else { return [] }
            return Array(((plainValue as? [AXUIElement]) ?? []).prefix(limit)).map(reference)
        } else {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(containerElement, childAttribute as CFString, &value) == .success else {
                // Some lists don't support visible children; fall back.
                guard AXUIElementCopyAttributeValues(containerElement, kAXChildrenAttribute as CFString, 0, limit, &childValues) == .success else { return [] }
                return ((childValues as? [AXUIElement]) ?? []).map(reference)
            }
            return Array(((value as? [AXUIElement]) ?? []).prefix(limit)).map(reference)
        }
    }

    public func windows(of applicationNode: AXNodeReference) -> [AXNodeReference] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(applicationNode), kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return ((value as? [AXUIElement]) ?? []).map(reference)
    }

    public func menuBar(of applicationNode: AXNodeReference) -> AXNodeReference? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(applicationNode), kAXMenuBarAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return reference(value as! AXUIElement)
    }

    public func stringAttribute(_ attributeName: String, of node: AXNodeReference) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(node), attributeName as CFString, &value) == .success, let value else { return nil }
        if let stringValue = value as? String { return stringValue }
        if let numberValue = value as? NSNumber { return numberValue.stringValue }
        return nil
    }

    public func titleUIElementTitle(of node: AXNodeReference) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(node), kAXTitleUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        let titleElement = reference(value as! AXUIElement)
        return stringAttribute(kAXValueAttribute, of: titleElement) ?? stringAttribute(kAXTitleAttribute, of: titleElement)
    }

    public func focusedElement(of applicationNode: AXNodeReference) -> AXNodeReference? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(applicationNode), kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return reference(value as! AXUIElement)
    }

    public func isEqual(_ first: AXNodeReference, _ second: AXNodeReference) -> Bool {
        CFEqual(element(first), element(second))
    }

    public func parent(of node: AXNodeReference) -> AXNodeReference? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(node), kAXParentAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return reference(value as! AXUIElement)
    }

    public func processIdentifier(of node: AXNodeReference) -> pid_t? {
        var processIdentifier: pid_t = 0
        return AXUIElementGetPid(element(node), &processIdentifier) == .success ? processIdentifier : nil
    }

    public func element(at pointCG: CGPoint, inApplication applicationNode: AXNodeReference) -> AXNodeReference? {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(element(applicationNode), Float(pointCG.x), Float(pointCG.y), &hitElement) == .success,
              let hitElement else { return nil }
        return reference(hitElement)
    }

    public func systemWideElement(at pointCG: CGPoint) -> AXNodeReference? {
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(pointCG.x), Float(pointCG.y), &hitElement) == .success,
              let hitElement else { return nil }
        return reference(hitElement)
    }

    public func boundsForRange(_ range: NSRange, of node: AXNodeReference) -> CGRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let rangeValue = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element(node), kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds)
        return bounds.isEmpty ? nil : bounds
    }

    public func enableManualAccessibility(for applicationNode: AXNodeReference) {
        AXUIElementSetAttributeValue(element(applicationNode), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
