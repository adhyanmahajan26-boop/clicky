//
//  OwnWindowAccessibility.swift
//  leanring-buddy
//
//  Vello's own main windows (Home with its sidebar, Settings, Agents, Setup)
//  read from the inside. The AX walks skip this process on purpose: an AX
//  request to ourselves is answered by our own main thread, which is the
//  thread waiting for the answer. So these windows were only ever read by
//  OCR, which missed most of the sidebar's bot names (Air, 23 Nov: 37 of 37
//  elements in the Vello window were OCR, the names at the left absent) and
//  had nothing at all on the cold path, where OCR isn't waited for.
//
//  Here the same AXEnumerator walk runs over AppKit's in-process
//  accessibility objects (NSAccessibilityProtocol), on the main thread, with
//  no IPC, within a small budget. The elements carry no AX node, so nothing
//  later asks this process over AX for them; a click on them still waits for
//  the owner's yes, as before.
//

import AppKit
import ApplicationServices
import ClickyCore

@MainActor
enum OwnWindowAccessibility {
    /// Main-thread time the walk may take.
    static let budgetSeconds = 0.08

    /// The elements of Vello's own main windows that are in the window stack, and a line for the turn log.
    static func elements(windowStack: WindowStack) -> (elements: [GroundingElement], note: String?) {
        let ownProcessIdentifier = getpid()
        let ownWindowIDs = Set(windowStack.windows.filter { $0.processIdentifier == ownProcessIdentifier }.map(\.windowID))
        let ownWindows = TheoMainWindows.windows().filter { ownWindowIDs.contains(CGWindowID($0.windowNumber)) }
        guard !ownWindows.isEmpty else { return ([], nil) }

        let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == ownProcessIdentifier
        let request = AXEnumerationRequest(processIdentifier: ownProcessIdentifier, applicationName: "Vello",
                                           scope: isFrontmost ? .frontApplication : .otherApplication,
                                           maximumDepth: 40, allowsValues: true)
        let querying = InProcessAccessibilityQuerying(windows: ownWindows)
        let startDate = Date()
        let deadline = startDate.addingTimeInterval(budgetSeconds)
        var foundElements: [GroundingElement] = []
        var didReachDeadline = false
        do {
            try AXEnumerator.walk(request: request, ax: querying, windowStack: windowStack,
                                  shouldStop: {
                                      if Date() >= deadline { didReachDeadline = true }
                                      return didReachDeadline
                                  },
                                  publish: { foundElements.append($0) })
        } catch {
            return ([], "Vello own windows: \(error)")
        }
        // No AX node: these are AppKit objects, not AXUIElements, and nothing may ask this process over AX anyway.
        let elements = foundElements.map { element -> GroundingElement in
            var ownElement = element
            ownElement.axNode = nil
            return ownElement
        }
        let milliseconds = Int((Date().timeIntervalSince(startDate) * 1000).rounded())
        return (elements, "Vello own windows \(elements.count) (in-process, \(milliseconds) ms\(didReachDeadline ? ", deadline" : ""))")
    }
}

/// AXQuerying over this process's own AppKit accessibility objects. Main thread only: every call is made from the walk
/// above, which runs synchronously on the main actor.
final class InProcessAccessibilityQuerying: AXQuerying, @unchecked Sendable {
    private let windows: [NSWindow]
    private let mainDisplayHeight: CGFloat

    @MainActor
    init(windows: [NSWindow]) {
        self.windows = windows
        self.mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
    }

    private func object(_ node: AXNodeReference) -> NSAccessibilityProtocol? {
        node.underlyingObject as? NSAccessibilityProtocol
    }

    private func onMain<Value: Sendable>(_ body: @MainActor () -> Value) -> Value {
        MainActor.assumeIsolated(body)
    }

    func isProcessTrusted() -> Bool { true }

    func applicationNode(processIdentifier: pid_t) -> AXNodeReference {
        onMain { AXNodeReference(NSApp) }
    }

    func attributes(of node: AXNodeReference) -> AXNodeAttributes? {
        onMain {
            guard let element = object(node), let role = element.accessibilityRole()?.rawValue else { return nil }
            let frameAppKit = element.accessibilityFrame()
            let frameCG = frameAppKit.isEmpty ? nil : ScreenTopology.cg(fromAppKit: frameAppKit, flipH: mainDisplayHeight)
            return AXNodeAttributes(role: role, subrole: element.accessibilitySubrole()?.rawValue,
                                    title: element.accessibilityTitle(), elementDescription: element.accessibilityLabel(),
                                    frameCG: frameCG, isEnabled: element.isAccessibilityEnabled())
        }
    }

    func children(of node: AXNodeReference, role: String?, limit: Int) -> [AXNodeReference] {
        onMain {
            guard let element = object(node) else { return [] }
            let rawChildren: [Any]
            switch role {
            case "AXTable", "AXOutline":
                rawChildren = element.accessibilityVisibleRows() ?? element.accessibilityRows() ?? element.accessibilityChildren() ?? []
            case "AXList", "AXBrowser":
                rawChildren = element.accessibilityVisibleChildren() ?? element.accessibilityChildren() ?? []
            default:
                rawChildren = element.accessibilityChildren() ?? []
            }
            var unignoredChildren: [AXNodeReference] = []
            collectUnignored(rawChildren, into: &unignoredChildren, limit: limit, depth: 0)
            return unignoredChildren
        }
    }

    /// What an AX client sees as children: objects that aren't accessibility elements themselves (plain container
    /// views) are skipped and their own children take their place.
    @MainActor
    private func collectUnignored(_ rawChildren: [Any], into unignoredChildren: inout [AXNodeReference], limit: Int, depth: Int) {
        for rawChild in rawChildren {
            if unignoredChildren.count >= limit { return }
            guard let child = rawChild as? NSAccessibilityProtocol else { continue }
            if child.isAccessibilityElement() {
                unignoredChildren.append(AXNodeReference(child as AnyObject))
            } else if depth < 12, let grandchildren = child.accessibilityChildren(), !grandchildren.isEmpty {
                collectUnignored(grandchildren, into: &unignoredChildren, limit: limit, depth: depth + 1)
            }
        }
    }

    func windows(of applicationNode: AXNodeReference) -> [AXNodeReference] {
        windows.map { AXNodeReference($0) }
    }

    func menuBar(of applicationNode: AXNodeReference) -> AXNodeReference? { nil }

    func stringAttribute(_ attributeName: String, of node: AXNodeReference) -> String? {
        onMain {
            guard let element = object(node) else { return nil }
            switch attributeName {
            case kAXValueAttribute: return Self.text(of: element.accessibilityValue())
            case kAXTitleAttribute: return element.accessibilityTitle()
            case kAXDescriptionAttribute: return element.accessibilityLabel()
            case kAXHelpAttribute: return element.accessibilityHelp()
            case kAXPlaceholderValueAttribute: return element.accessibilityPlaceholderValue()
            case kAXRoleAttribute: return element.accessibilityRole()?.rawValue
            case kAXSubroleAttribute: return element.accessibilitySubrole()?.rawValue
            default: return nil
            }
        }
    }

    private static func text(of value: Any?) -> String? {
        switch value {
        case let stringValue as String: return stringValue
        case let attributedValue as NSAttributedString: return attributedValue.string
        case let numberValue as NSNumber: return numberValue.stringValue
        default: return nil
        }
    }

    func titleUIElementTitle(of node: AXNodeReference) -> String? {
        onMain {
            guard let titleElement = object(node)?.accessibilityTitleUIElement() as? NSAccessibilityProtocol else { return nil }
            return Self.text(of: titleElement.accessibilityValue()) ?? titleElement.accessibilityTitle()
        }
    }

    func focusedElement(of applicationNode: AXNodeReference) -> AXNodeReference? {
        onMain { NSApp.accessibilityFocusedUIElement.map { AXNodeReference($0 as AnyObject) } }
    }

    func isEqual(_ first: AXNodeReference, _ second: AXNodeReference) -> Bool {
        first.underlyingObject === second.underlyingObject
    }

    func parent(of node: AXNodeReference) -> AXNodeReference? {
        onMain { object(node)?.accessibilityParent().map { AXNodeReference($0 as AnyObject) } }
    }

    func processIdentifier(of node: AXNodeReference) -> pid_t? { getpid() }

    // Hit tests and text ranges aren't needed for the walk; own elements carry no AX node afterwards.
    func element(at pointCG: CGPoint, inApplication applicationNode: AXNodeReference) -> AXNodeReference? { nil }
    func systemWideElement(at pointCG: CGPoint) -> AXNodeReference? { nil }
    func boundsForRange(_ range: NSRange, of node: AXNodeReference) -> CGRect? { nil }
    func enableManualAccessibility(for applicationNode: AXNodeReference) {}
}
