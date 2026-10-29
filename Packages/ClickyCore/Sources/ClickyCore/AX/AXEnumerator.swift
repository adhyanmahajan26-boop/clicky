//
//  AXEnumerator.swift
//  ClickyCore
//
//  Walks apps' accessibility trees into GroundingElements. The walk itself
//  (`AXEnumerator.walk`) is synchronous and only talks to `AXQuerying`, so it
//  is unit-tested with a mock. `AXAppWalk` runs one walk on its own thread
//  (AX calls block, so they never touch the cooperative pool) and publishes
//  results as it goes; at a deadline the caller takes whatever is there.
//
//  Per node: one CopyMultipleAttributeValues (role, subrole, title, desc,
//  position, size, enabled); children via visible rows/children for
//  tables/lists, else the first 400 children; at most 2500 nodes and depth 40.
//  Frames are clipped by scroll areas, web areas, windows, split groups,
//  lists, tables and outlines; anything under 2x2 visible is pruned.
//

import ApplicationServices
import CoreGraphics
import Foundation

public struct AXEnumerationRequest: Sendable {
    public enum Scope: Sendable {
        /// The frontmost app: every window matched to an on-screen CG window.
        case frontApplication
        /// Another app with on-screen windows: shallower walk.
        case otherApplication
        /// The front app's menu bar items, plus open menus.
        case menuBar
        /// The Dock's items.
        case dock
    }

    public let processIdentifier: pid_t
    public let applicationName: String
    public let scope: Scope
    public let maximumDepth: Int
    public let allowsValues: Bool
    public let isElectron: Bool

    public init(processIdentifier: pid_t, applicationName: String, scope: Scope, maximumDepth: Int, allowsValues: Bool, isElectron: Bool = false) {
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        self.scope = scope
        self.maximumDepth = maximumDepth
        self.allowsValues = allowsValues
        self.isElectron = isElectron
    }
}

public enum AXEnumerator {
    public static let maximumNodeCount = 2500
    public static let maximumChildrenPerNode = 400

    static let clippingRoles: Set<String> = ["AXScrollArea", "AXWebArea", "AXWindow", "AXSplitGroup", "AXList", "AXTable", "AXOutline"]
    static let valueRoles: Set<String> = ["AXTextField", "AXCheckBox", "AXPopUpButton", "AXStaticText", "AXSlider"]
    static let joinsDescendantTextRoles: Set<String> = ["AXRow", "AXCell", "AXButton", "AXLink"]

    /// AX role (+ subrole) → list role, or nil when not emitted.
    static func groundingRole(role: String, subrole: String?) -> GroundingRole? {
        switch role {
        case "AXButton", "AXMenuButton", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell": return .button
        case "AXCheckBox": return .checkBox
        case "AXRadioButton": return subrole == "AXTabButton" ? .tab : .radio
        case "AXPopUpButton": return .popUp
        case "AXComboBox", "AXTextField": return .textField
        case "AXTextArea": return .textArea
        case "AXMenuItem": return .menuItem
        case "AXMenuBarItem": return .menu
        case "AXSlider": return .slider
        case "AXLink": return .link
        case "AXDockItem": return .dock
        case "AXStaticText", "AXHeading": return .text
        case "AXImage": return .image
        case "AXCell": return .cell
        case "AXRow": return .row
        default: return nil
        }
    }

    static func isInteractive(role: String) -> Bool {
        !["AXStaticText", "AXImage", "AXHeading"].contains(role)
    }

    /// Walks one app. `shouldStop` is checked before every node; `publish`
    /// receives elements as they're found. Throws when the app itself (or
    /// its window list) can't be read: then that app has no AX at all.
    /// `publishWindow` gets each on-screen window's AX node (the AX cache's
    /// observer maps notifications back to windows with them).
    public static func walk(request: AXEnumerationRequest, ax: AXQuerying, windowStack: WindowStack,
                            shouldStop: @escaping () -> Bool, publish: @escaping (GroundingElement) -> Void,
                            publishWindow: ((CGWindowID, AXNodeReference) -> Void)? = nil) throws {
        let applicationNode = ax.applicationNode(processIdentifier: request.processIdentifier)
        if request.isElectron {
            ax.enableManualAccessibility(for: applicationNode)
        }
        let focusedNode = ax.focusedElement(of: applicationNode)
        var visitor = NodeVisitor(request: request, ax: ax, windowStack: windowStack, focusedNode: focusedNode,
                                  shouldStop: shouldStop, publish: publish)

        switch request.scope {
        case .frontApplication, .otherApplication:
            let windowNodes = ax.windows(of: applicationNode)
            guard !windowNodes.isEmpty || ax.attributes(of: applicationNode) != nil else {
                throw AXEnumerationError.applicationUnavailable(request.processIdentifier)
            }
            // The app's frontmost on-screen window is its "front window".
            let frontWindowID = windowStack.windows.first { $0.processIdentifier == request.processIdentifier && $0.isApplicationWindowLayer }?.windowID
            for windowNode in windowNodes {
                if shouldStop() { return }
                guard let windowAttributes = ax.attributes(of: windowNode), let windowFrame = windowAttributes.frameCG,
                      let matchedWindow = windowStack.matchWindow(processIdentifier: request.processIdentifier, axBoundsCG: windowFrame, axTitle: windowAttributes.title) else {
                    continue // not an on-screen window
                }
                publishWindow?(matchedWindow.windowID, windowNode)
                let windowContext = WindowContext(
                    windowID: matchedWindow.windowID,
                    title: windowAttributes.title ?? matchedWindow.title,
                    zIndex: windowStack.zIndex(of: matchedWindow.windowID) ?? 0,
                    isFrontWindow: request.scope == .frontApplication && matchedWindow.windowID == frontWindowID,
                    isSystemChrome: false
                )
                visitor.visit(windowNode, attributes: windowAttributes, depth: 0, clipRect: windowFrame, window: windowContext, suppressedTextDepth: 0)
            }

        case .menuBar:
            guard let menuBarNode = ax.menuBar(of: applicationNode) else { return }
            let chromeContext = WindowContext(windowID: nil, title: nil, zIndex: -1, isFrontWindow: false, isSystemChrome: true)
            let openMenuFrames = windowStack.windows.filter { $0.layer == 101 && $0.processIdentifier == request.processIdentifier }.map(\.boundsCG)
            for menuBarItemNode in ax.children(of: menuBarNode, role: "AXMenuBar", limit: maximumChildrenPerNode) {
                if shouldStop() { return }
                guard let itemAttributes = ax.attributes(of: menuBarItemNode) else { continue }
                visitor.emitIfListed(menuBarItemNode, attributes: itemAttributes, visibleFrame: itemAttributes.frameCG ?? .null, window: chromeContext, joinedText: nil)
                // Open menus (layer 101 windows): walk this item's menu, keep items inside them.
                if !openMenuFrames.isEmpty {
                    visitor.visitOpenMenu(under: menuBarItemNode, openMenuFrames: openMenuFrames, window: chromeContext)
                }
            }

        case .dock:
            let chromeContext = WindowContext(windowID: nil, title: nil, zIndex: -1, isFrontWindow: false, isSystemChrome: true)
            for dockChild in ax.children(of: applicationNode, role: nil, limit: maximumChildrenPerNode) {
                if shouldStop() { return }
                guard let childAttributes = ax.attributes(of: dockChild) else { continue }
                let unboundedClip = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)
                visitor.visit(dockChild, attributes: childAttributes, depth: 0, clipRect: unboundedClip, window: chromeContext, suppressedTextDepth: 0)
            }
        }
    }

    struct WindowContext {
        let windowID: CGWindowID?
        let title: String?
        let zIndex: Int
        let isFrontWindow: Bool
        let isSystemChrome: Bool
    }

    struct NodeVisitor {
        let request: AXEnumerationRequest
        let ax: AXQuerying
        let windowStack: WindowStack
        let focusedNode: AXNodeReference?
        let shouldStop: () -> Bool
        let publish: (GroundingElement) -> Void
        var visitedNodeCount = 0

        init(request: AXEnumerationRequest, ax: AXQuerying, windowStack: WindowStack, focusedNode: AXNodeReference?,
             shouldStop: @escaping () -> Bool, publish: @escaping (GroundingElement) -> Void) {
            self.request = request
            self.ax = ax
            self.windowStack = windowStack
            self.focusedNode = focusedNode
            self.shouldStop = shouldStop
            self.publish = publish
        }

        mutating func visit(_ node: AXNodeReference, attributes nodeAttributes: AXNodeAttributes, depth: Int, clipRect: CGRect,
                            window: WindowContext, suppressedTextDepth: Int) {
            guard !shouldStop(), visitedNodeCount < AXEnumerator.maximumNodeCount, depth <= 40 else { return }
            visitedNodeCount += 1

            let role = nodeAttributes.role ?? ""
            var visibleFrame = clipRect
            if let nodeFrame = nodeAttributes.frameCG {
                visibleFrame = nodeFrame.intersection(clipRect)
                // Prune what can't be seen (and everything under it).
                if visibleFrame.isNull || visibleFrame.width < 2 || visibleFrame.height < 2 { return }
            }

            var childSuppressedTextDepth = max(0, suppressedTextDepth - 1)
            let isSuppressedText = suppressedTextDepth > 0 && (role == "AXStaticText")
            if !isSuppressedText, nodeAttributes.frameCG != nil {
                var joinedText: String?
                if AXEnumerator.joinsDescendantTextRoles.contains(role), Self.directLabel(nodeAttributes) == nil {
                    joinedText = descendantStaticTexts(of: node, role: role)
                    if joinedText != nil { childSuppressedTextDepth = 3 }
                }
                emitIfListed(node, attributes: nodeAttributes, visibleFrame: visibleFrame, window: window, joinedText: joinedText)
            }

            guard depth < request.maximumDepth else { return }
            let childClip = AXEnumerator.clippingRoles.contains(role) ? visibleFrame : clipRect
            for childNode in ax.children(of: node, role: role, limit: AXEnumerator.maximumChildrenPerNode) {
                if shouldStop() || visitedNodeCount >= AXEnumerator.maximumNodeCount { return }
                guard let childAttributes = ax.attributes(of: childNode) else { continue } // node error: skip it
                visit(childNode, attributes: childAttributes, depth: depth + 1, clipRect: childClip, window: window,
                      suppressedTextDepth: childSuppressedTextDepth)
            }
        }

        /// Open menus: items under this menu bar item that sit inside an open
        /// menu window (layer 101).
        mutating func visitOpenMenu(under menuBarItemNode: AXNodeReference, openMenuFrames: [CGRect], window: WindowContext) {
            var pendingNodes: [(AXNodeReference, Int)] = ax.children(of: menuBarItemNode, role: nil, limit: AXEnumerator.maximumChildrenPerNode).map { ($0, 1) }
            while let (node, depth) = pendingNodes.popLast(), !shouldStop(), visitedNodeCount < AXEnumerator.maximumNodeCount {
                visitedNodeCount += 1
                guard let nodeAttributes = ax.attributes(of: node) else { continue }
                if nodeAttributes.role == "AXMenuItem", let itemFrame = nodeAttributes.frameCG,
                   openMenuFrames.contains(where: { $0.contains(itemFrame.center) }) {
                    emitIfListed(node, attributes: nodeAttributes, visibleFrame: itemFrame, window: window, joinedText: nil)
                }
                if depth < 4 {
                    pendingNodes += ax.children(of: node, role: nodeAttributes.role, limit: AXEnumerator.maximumChildrenPerNode).map { ($0, depth + 1) }
                }
            }
        }

        static func directLabel(_ nodeAttributes: AXNodeAttributes) -> String? {
            [nodeAttributes.title, nodeAttributes.elementDescription].compactMap { $0 }.first { !$0.isEmpty }
        }

        /// Up to 2 StaticTexts within 3 levels, joined, for unlabelled rows,
        /// cells, buttons and links.
        func descendantStaticTexts(of node: AXNodeReference, role: String) -> String? {
            var foundTexts: [String] = []
            var pendingNodes: [(AXNodeReference, Int, String?)] = [(node, 0, role)]
            while let (currentNode, depth, currentRole) = pendingNodes.first, foundTexts.count < 2 {
                pendingNodes.removeFirst()
                guard depth < 3 else { continue }
                for childNode in ax.children(of: currentNode, role: currentRole, limit: 50) {
                    guard let childAttributes = ax.attributes(of: childNode) else { continue }
                    if childAttributes.role == "AXStaticText",
                       let text = ax.stringAttribute(kAXValueAttribute, of: childNode) ?? childAttributes.title, !text.isEmpty {
                        foundTexts.append(text)
                        if foundTexts.count == 2 { break }
                    } else {
                        pendingNodes.append((childNode, depth + 1, childAttributes.role))
                    }
                }
            }
            return foundTexts.isEmpty ? nil : foundTexts.joined(separator: " ")
        }

        mutating func emitIfListed(_ node: AXNodeReference, attributes nodeAttributes: AXNodeAttributes, visibleFrame: CGRect,
                                   window: WindowContext, joinedText: String?) {
            guard let role = nodeAttributes.role,
                  let groundingRole = AXEnumerator.groundingRole(role: role, subrole: nodeAttributes.subrole),
                  let nodeFrame = nodeAttributes.frameCG,
                  !visibleFrame.isNull, visibleFrame.width >= 4, visibleFrame.height >= 4 else { return }

            let isSecure = nodeAttributes.subrole == "AXSecureTextField"
            // Label: title → description → value (text roles) → placeholder
            // → title element → help; later steps only while still unlabelled.
            var label = Self.directLabel(nodeAttributes)
            var fetchedValue: String?
            if label == nil, role == "AXStaticText" || role == "AXHeading" {
                fetchedValue = ax.stringAttribute(kAXValueAttribute, of: node)
                label = fetchedValue.flatMap { $0.isEmpty ? nil : $0 }
            }
            if label == nil { label = nonEmpty(ax.stringAttribute(kAXPlaceholderValueAttribute, of: node)) }
            if label == nil { label = nonEmpty(ax.titleUIElementTitle(of: node)) }
            if label == nil { label = nonEmpty(joinedText) }
            if label == nil { label = nonEmpty(ax.stringAttribute(kAXHelpAttribute, of: node)) }

            var value: String?
            if request.allowsValues, !isSecure, AXEnumerator.valueRoles.contains(role), role != "AXStaticText" {
                value = nonEmpty(fetchedValue ?? ax.stringAttribute(kAXValueAttribute, of: node))
            }

            let displayID = windowStack.displays.first { $0.boundsCG.contains(visibleFrame.center) }?.displayID
                ?? windowStack.displays.first?.displayID ?? 0
            let isFocused = focusedNode.map { ax.isEqual(node, $0) } ?? false

            publish(GroundingElement(
                role: groundingRole,
                label: label,
                value: value,
                frameCG: nodeFrame,
                visibleFrameCG: visibleFrame,
                processIdentifier: request.processIdentifier,
                windowID: window.windowID,
                windowTitle: window.title,
                applicationName: request.applicationName,
                displayID: displayID,
                isInteractive: AXEnumerator.isInteractive(role: role),
                isEnabled: nodeAttributes.isEnabled,
                isFocused: isFocused,
                isInFrontWindow: window.isFrontWindow,
                isSystemChrome: window.isSystemChrome,
                source: .accessibility,
                windowZIndex: window.zIndex,
                axNode: node
            ))
        }

        private func nonEmpty(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }
}

public enum AXEnumerationError: Error, Equatable {
    case applicationUnavailable(pid_t)
}

/// One app's walk on its own thread. Results are published under a lock as
/// they're found; `snapshot()` returns whatever exists at a deadline.
public final class AXAppWalk: @unchecked Sendable {
    public let request: AXEnumerationRequest
    private let lock = NSLock()
    private var publishedElements: [GroundingElement] = []
    private var publishedWindowNodes: [CGWindowID: AXNodeReference] = [:]
    private var isStopRequested = false
    private var isWalkFinished = false
    private var walkError: Error?
    private let finishedSemaphore = DispatchSemaphore(value: 0)

    public init(request: AXEnumerationRequest, ax: AXQuerying, windowStack: WindowStack) {
        self.request = request
        let walkThread = Thread { [weak self] in
            guard let self else { return }
            do {
                try AXEnumerator.walk(request: request, ax: ax, windowStack: windowStack, shouldStop: { [weak self] in
                    guard let self else { return true }
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self.isStopRequested
                }, publish: { [weak self] element in
                    guard let self else { return }
                    self.lock.lock(); self.publishedElements.append(element); self.lock.unlock()
                }, publishWindow: { [weak self] windowID, windowNode in
                    guard let self else { return }
                    self.lock.lock(); self.publishedWindowNodes[windowID] = windowNode; self.lock.unlock()
                })
            } catch {
                self.lock.lock(); self.walkError = error; self.lock.unlock()
            }
            self.lock.lock(); self.isWalkFinished = true; self.lock.unlock()
            self.finishedSemaphore.signal()
        }
        walkThread.name = "clicky.ax.\(request.processIdentifier)"
        walkThread.qualityOfService = .userInitiated
        walkThread.start()
    }

    /// Waits until the walk finishes or the deadline passes, then stops it and
    /// returns what was found. An app-level error returns nothing.
    public func elements(waitingUntil deadline: DispatchTime) -> (elements: [GroundingElement], didFinish: Bool, error: Error?) {
        _ = finishedSemaphore.wait(timeout: deadline)
        lock.lock(); defer { lock.unlock() }
        isStopRequested = true
        if walkError != nil { return ([], isWalkFinished, walkError) }
        return (publishedElements, isWalkFinished, nil)
    }

    /// The AX nodes of the windows walked so far, by CG window id.
    public var windowNodesByWindowID: [CGWindowID: AXNodeReference] {
        lock.lock(); defer { lock.unlock() }
        return publishedWindowNodes
    }

    public func cancel() {
        lock.lock(); isStopRequested = true; lock.unlock()
    }
}
