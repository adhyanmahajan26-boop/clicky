//
//  TypeForMeAccessibility.swift
//  leanring-buddy
//
//  The Accessibility reads and writes "Type this for me" needs: the
//  focused element of an app, its role/subrole/title (never its value for
//  the card), the caret rect (AXBoundsForRange of the selected range), the
//  value for verification, setting kAXSelectedTextAttribute, and the app's
//  menu bar items modelled as MenuItemDescriptor so PasteMenuFinder can
//  pick plain ⌘V Paste and the item can be AXPressed.
//

import AppKit
import ApplicationServices
import ClickyCore

enum TypeForMeAccessibility {
    static let messagingTimeoutSeconds: Float = 0.25

    static func applicationElement(processIdentifier: pid_t) -> AXUIElement {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, messagingTimeoutSeconds)
        return applicationElement
    }

    static func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement(processIdentifier: processIdentifier), kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (focusedValue as! AXUIElement)
    }

    static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func intAttribute(_ attributeName: String, of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.intValue
    }

    static func boolAttribute(_ attributeName: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    static func elementArrayAttribute(_ attributeName: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// The field's readable value, nil when it has none or it isn't a string.
    static func value(of element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, of: element)
    }

    /// "text area · Message to Adhyan": role plus title/description/placeholder.
    static func fieldDescription(of element: AXUIElement) -> String {
        let role = TypeForMePolicy.readableRole(stringAttribute(kAXRoleAttribute, of: element))
        let titleCandidates = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
        let title = titleCandidates.lazy.compactMap { stringAttribute($0, of: element)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        guard let title else { return role }
        return "\(role) · \(title.count > 60 ? String(title.prefix(59)) + "…" : title)"
    }

    static func frameCG(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        // swiftlint:enable force_cast
        return CGRect(origin: position, size: size)
    }

    /// The caret (or selection) rect in CG global points; a zero-width caret counts.
    static func caretRectCG(of element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var boundsValue: CFTypeRef?
        // swiftlint:disable:next force_cast
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue as! AXValue, &boundsValue) == .success,
              let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        // swiftlint:disable:next force_cast
        AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds)
        guard bounds.height > 0, bounds.origin != .zero || bounds.width > 0 else { return nil }
        return bounds
    }

    /// Method (a): replace the selection (or insert at the caret).
    static func setSelectedText(_ text: String, of element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }

    // MARK: - Menu bar

    /// Every item of every top-level menu (Apple menu skipped), with its shortcut.
    static func menuItems(processIdentifier: pid_t) -> (descriptors: [MenuItemDescriptor], elementsByPath: [[Int]: AXUIElement]) {
        let applicationElement = applicationElement(processIdentifier: processIdentifier)
        var menuBarValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(applicationElement, kAXMenuBarAttribute as CFString, &menuBarValue) == .success,
              let menuBarValue, CFGetTypeID(menuBarValue) == AXUIElementGetTypeID() else { return ([], [:]) }
        // swiftlint:disable:next force_cast
        let menuBar = menuBarValue as! AXUIElement
        var descriptors: [MenuItemDescriptor] = []
        var elementsByPath: [[Int]: AXUIElement] = [:]
        for (menuBarItemIndex, menuBarItem) in elementArrayAttribute(kAXChildrenAttribute, of: menuBar).enumerated() where menuBarItemIndex > 0 {
            guard let menu = elementArrayAttribute(kAXChildrenAttribute, of: menuBarItem).first else { continue }
            for (itemIndex, menuItem) in elementArrayAttribute(kAXChildrenAttribute, of: menu).enumerated() {
                guard let commandCharacter = stringAttribute(kAXMenuItemCmdCharAttribute, of: menuItem), !commandCharacter.isEmpty else { continue }
                let path = [menuBarItemIndex, itemIndex]
                descriptors.append(MenuItemDescriptor(title: stringAttribute(kAXTitleAttribute, of: menuItem) ?? "",
                                                      commandCharacter: commandCharacter,
                                                      commandModifiers: intAttribute(kAXMenuItemCmdModifiersAttribute, of: menuItem),
                                                      isEnabled: boolAttribute(kAXEnabledAttribute, of: menuItem) ?? false,
                                                      path: path))
                elementsByPath[path] = menuItem
            }
        }
        return (descriptors, elementsByPath)
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
}
