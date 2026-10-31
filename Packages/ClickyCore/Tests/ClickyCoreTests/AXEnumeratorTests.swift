import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import ClickyCore

// MARK: - Mock accessibility tree

/// One node of a mock accessibility tree.
final class MockNode {
    var role: String?
    var subrole: String?
    var title: String?
    var desc: String?
    var frame: CGRect?
    var enabled: Bool
    var value: String?
    var placeholder: String?
    var children: [MockNode]
    weak var parent: MockNode?
    var pid: pid_t?
    /// When true, `attributes(of:)` returns nil for this node (a node error).
    var attributesFail = false

    init(role: String?, subrole: String? = nil, title: String? = nil, desc: String? = nil, frame: CGRect? = nil,
         enabled: Bool = true, value: String? = nil, placeholder: String? = nil, pid: pid_t? = nil, children: [MockNode] = []) {
        self.role = role
        self.subrole = subrole
        self.title = title
        self.desc = desc
        self.frame = frame
        self.enabled = enabled
        self.value = value
        self.placeholder = placeholder
        self.pid = pid
        self.children = children
        for child in children {
            child.parent = self
        }
    }

    @discardableResult
    func add(_ child: MockNode) -> MockNode {
        child.parent = self
        children.append(child)
        return child
    }
}

/// An in-memory `AXQuerying`. `apps` are listed front-most first.
final class MockAXQuerying: AXQuerying, @unchecked Sendable {
    let apps: [MockNode]
    var focusedNode: MockNode?

    init(apps: [MockNode], focusedNode: MockNode? = nil) {
        self.apps = apps
        self.focusedNode = focusedNode
    }

    private func node(_ reference: AXNodeReference) -> MockNode? {
        reference.underlyingObject as? MockNode
    }

    private func reference(_ mockNode: MockNode) -> AXNodeReference {
        AXNodeReference(mockNode)
    }

    /// Deepest node whose frame contains the point; later children are in front.
    static func deepestHit(in mockNode: MockNode, at point: CGPoint) -> MockNode? {
        for child in mockNode.children.reversed() {
            if let hit = deepestHit(in: child, at: point) {
                return hit
            }
        }
        if let frame = mockNode.frame, frame.contains(point) {
            return mockNode
        }
        return nil
    }

    func isProcessTrusted() -> Bool { true }

    func applicationNode(processIdentifier: pid_t) -> AXNodeReference {
        reference(apps.first { $0.pid == processIdentifier } ?? MockNode(role: "AXApplication", pid: processIdentifier))
    }

    func attributes(of node: AXNodeReference) -> AXNodeAttributes? {
        guard let mockNode = self.node(node), !mockNode.attributesFail else { return nil }
        return AXNodeAttributes(role: mockNode.role, subrole: mockNode.subrole, title: mockNode.title,
                                elementDescription: mockNode.desc, frameCG: mockNode.frame, isEnabled: mockNode.enabled)
    }

    func children(of node: AXNodeReference, role: String?, limit: Int) -> [AXNodeReference] {
        guard let mockNode = self.node(node) else { return [] }
        return mockNode.children.prefix(limit).map { reference($0) }
    }

    func windows(of applicationNode: AXNodeReference) -> [AXNodeReference] {
        guard let mockNode = self.node(applicationNode) else { return [] }
        return mockNode.children.filter { $0.role == "AXWindow" }.map { reference($0) }
    }

    func menuBar(of applicationNode: AXNodeReference) -> AXNodeReference? { nil }

    func stringAttribute(_ attributeName: String, of node: AXNodeReference) -> String? {
        guard let mockNode = self.node(node) else { return nil }
        switch attributeName {
        case kAXValueAttribute:
            return mockNode.value
        case kAXPlaceholderValueAttribute:
            return mockNode.placeholder
        default:
            return nil
        }
    }

    func titleUIElementTitle(of node: AXNodeReference) -> String? { nil }

    func focusedElement(of applicationNode: AXNodeReference) -> AXNodeReference? {
        focusedNode.map { reference($0) }
    }

    func isEqual(_ first: AXNodeReference, _ second: AXNodeReference) -> Bool {
        guard let firstNode = node(first), let secondNode = node(second) else { return false }
        return firstNode === secondNode
    }

    func parent(of node: AXNodeReference) -> AXNodeReference? {
        guard let mockNode = self.node(node), let parentNode = mockNode.parent else { return nil }
        return reference(parentNode)
    }

    func processIdentifier(of node: AXNodeReference) -> pid_t? {
        var current = self.node(node)
        while let currentNode = current {
            if let pid = currentNode.pid {
                return pid
            }
            current = currentNode.parent
        }
        return nil
    }

    func element(at pointCG: CGPoint, inApplication applicationNode: AXNodeReference) -> AXNodeReference? {
        guard let appNode = node(applicationNode), let hit = Self.deepestHit(in: appNode, at: pointCG) else { return nil }
        return reference(hit)
    }

    func systemWideElement(at pointCG: CGPoint) -> AXNodeReference? {
        for app in apps {
            if let hit = Self.deepestHit(in: app, at: pointCG) {
                return reference(hit)
            }
        }
        return nil
    }

    func boundsForRange(_ range: NSRange, of node: AXNodeReference) -> CGRect? { nil }

    func enableManualAccessibility(for applicationNode: AXNodeReference) {}
}

// MARK: - Fixtures

private let axDisplay = DisplayInfo(
    displayID: 1,
    localizedName: "Main",
    boundsCG: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    visibleCG: CGRect(x: 0, y: 30, width: 3440, height: 1410),
    frameAppKit: CGRect(x: 0, y: 0, width: 3440, height: 1440),
    isMain: true
)

private let mailWindowFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)

private func mailWindowInfo(frame: CGRect = mailWindowFrame) -> WindowInfo {
    WindowInfo(windowID: 10, processIdentifier: 42, layer: 0, boundsCG: frame, alpha: 1, ownerName: "Mail", title: "Inbox")
}

private func button(_ title: String?, frame: CGRect, desc: String? = nil, children: [MockNode] = []) -> MockNode {
    MockNode(role: "AXButton", title: title, desc: desc, frame: frame, children: children)
}

/// Mail (pid 42) with one window "Inbox" holding `content`.
private func mailApp(content: [MockNode]) -> (app: MockNode, window: MockNode) {
    let app = MockNode(role: "AXApplication", title: "Mail", pid: 42)
    let window = MockNode(role: "AXWindow", title: "Inbox", frame: mailWindowFrame, children: content)
    app.add(window)
    return (app, window)
}

/// Walks the front app (pid 42) with the Inbox window on screen.
private func walkMail(
    _ ax: MockAXQuerying,
    windows: [WindowInfo] = [mailWindowInfo()],
    allowsValues: Bool = true,
    shouldStop: @escaping () -> Bool = { false }
) throws -> [GroundingElement] {
    let stack = WindowStack(windows: windows, ownProcessIdentifier: 1, displays: [axDisplay])
    var published: [GroundingElement] = []
    try AXEnumerator.walk(
        request: AXEnumerationRequest(processIdentifier: 42, applicationName: "Mail", scope: .frontApplication,
                                      maximumDepth: 12, allowsValues: allowsValues),
        ax: ax,
        windowStack: stack,
        shouldStop: shouldStop,
        publish: { published.append($0) }
    )
    return published
}

private func labelled(_ label: String, in elements: [GroundingElement]) -> GroundingElement? {
    elements.first { $0.label == label }
}

// MARK: - Role mapping

@Test func axRolesMapToListRoles() {
    #expect(AXEnumerator.groundingRole(role: "AXButton", subrole: nil) == .button)
    #expect(AXEnumerator.groundingRole(role: "AXCheckBox", subrole: nil) == .checkBox)
    #expect(AXEnumerator.groundingRole(role: "AXLink", subrole: nil) == .link)
    #expect(AXEnumerator.groundingRole(role: "AXPopUpButton", subrole: nil) == .popUp)
    #expect(AXEnumerator.groundingRole(role: "AXRadioButton", subrole: nil) == .radio)
    #expect(AXEnumerator.groundingRole(role: "AXRadioButton", subrole: "AXTabButton") == .tab)
    #expect(AXEnumerator.groundingRole(role: "AXTextField", subrole: nil) == .textField)
    #expect(AXEnumerator.groundingRole(role: "AXStaticText", subrole: nil) == .text)
    #expect(AXEnumerator.groundingRole(role: "AXRow", subrole: nil) == .row)
    #expect(AXEnumerator.groundingRole(role: "AXTabGroup", subrole: nil) == nil)
    #expect(AXEnumerator.groundingRole(role: "AXGroup", subrole: nil) == nil)
}

// MARK: - Walk

@Test func walkEmitsMappedRolesAndSkipsContainerButWalksItsChildren() throws {
    let content = [
        button("Save", frame: CGRect(x: 10, y: 10, width: 80, height: 30)),
        MockNode(role: "AXStaticText", frame: CGRect(x: 10, y: 50, width: 100, height: 20), value: "Hello"),
        MockNode(role: "AXTextField", frame: CGRect(x: 10, y: 80, width: 200, height: 24), value: "query", placeholder: "Search"),
        MockNode(role: "AXTabGroup", frame: CGRect(x: 300, y: 10, width: 300, height: 40),
                 children: [button("Tab1", frame: CGRect(x: 310, y: 12, width: 80, height: 30))]),
    ]
    let (app, _) = mailApp(content: content)
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(elements.count == 4)
    #expect(labelled("Save", in: elements)?.role == .button)
    #expect(labelled("Hello", in: elements)?.role == .text)
    #expect(labelled("Search", in: elements)?.role == .textField)
    #expect(labelled("Search", in: elements)?.value == "query")
    #expect(labelled("Tab1", in: elements)?.role == .button)
    #expect(elements.allSatisfy { $0.processIdentifier == 42 && $0.windowID == 10 && $0.windowTitle == "Inbox" })
    #expect(elements.allSatisfy { $0.applicationName == "Mail" && $0.displayID == 1 })
}

@Test func labelsComeFromTitleThenDescriptionThenPlaceholder() throws {
    let content = [
        button("Title", frame: CGRect(x: 10, y: 10, width: 80, height: 30), desc: "Desc"),
        button(nil, frame: CGRect(x: 100, y: 10, width: 80, height: 30), desc: "Desc only"),
        MockNode(role: "AXTextField", frame: CGRect(x: 10, y: 60, width: 200, height: 24), placeholder: "Search"),
    ]
    let (app, _) = mailApp(content: content)
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(labelled("Title", in: elements) != nil)
    #expect(labelled("Desc", in: elements) == nil)
    #expect(labelled("Desc only", in: elements)?.role == .button)
    #expect(labelled("Search", in: elements)?.role == .textField)
}

@Test func unlabelledRowJoinsUpToTwoDescendantStaticTexts() throws {
    let content = [
        MockNode(role: "AXRow", frame: CGRect(x: 10, y: 100, width: 300, height: 24), children: [
            MockNode(role: "AXStaticText", frame: CGRect(x: 12, y: 102, width: 50, height: 20), value: "Alpha"),
            MockNode(role: "AXStaticText", frame: CGRect(x: 70, y: 102, width: 50, height: 20), value: "Beta"),
            MockNode(role: "AXStaticText", frame: CGRect(x: 130, y: 102, width: 50, height: 20), value: "Gamma"),
        ]),
    ]
    let (app, _) = mailApp(content: content)
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    let row = elements.first { $0.role == .row }
    #expect(row?.label == "Alpha Beta")
    // The joined texts are not emitted again on their own.
    #expect(labelled("Alpha", in: elements) == nil)
    #expect(labelled("Beta", in: elements) == nil)
    #expect(labelled("Gamma", in: elements) == nil)
    #expect(elements.count == 1)
}

@Test func secureTextFieldNeverReportsAValue() throws {
    let content = [
        MockNode(role: "AXTextField", subrole: "AXSecureTextField", title: "Password",
                 frame: CGRect(x: 10, y: 10, width: 200, height: 24), value: "hunter2"),
    ]
    let (app, _) = mailApp(content: content)
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(elements.count == 1)
    #expect(elements.first?.label == "Password")
    #expect(elements.first?.value == nil)
}

@Test func valuesAreNotReadWhenTheRequestDisallowsThem() throws {
    let content = [
        MockNode(role: "AXTextField", title: "Name", frame: CGRect(x: 10, y: 10, width: 200, height: 24), value: "abc"),
    ]
    let (app, _) = mailApp(content: content)
    let ax = MockAXQuerying(apps: [app])

    let withoutValues = try walkMail(ax, allowsValues: false)
    #expect(withoutValues.first?.value == nil)

    let withValues = try walkMail(ax, allowsValues: true)
    #expect(withValues.first?.value == "abc")
}

@Test func elementsFullyClippedByAScrollAreaAreNotEmitted() throws {
    let scrollArea = MockNode(role: "AXScrollArea", frame: CGRect(x: 10, y: 10, width: 300, height: 300), children: [
        button("Shown", frame: CGRect(x: 20, y: 20, width: 50, height: 30)),
        button("Hidden", frame: CGRect(x: 400, y: 400, width: 50, height: 50)),
    ])
    let (app, _) = mailApp(content: [scrollArea])
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(labelled("Shown", in: elements) != nil)
    #expect(labelled("Hidden", in: elements) == nil)
}

@Test func elementsSmallerThanFourByFourAreNotEmitted() throws {
    let content = [
        button("Tiny", frame: CGRect(x: 100, y: 100, width: 3, height: 3)),
        button("Ok", frame: CGRect(x: 100, y: 120, width: 4, height: 4)),
    ]
    let (app, _) = mailApp(content: content)
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(labelled("Tiny", in: elements) == nil)
    #expect(labelled("Ok", in: elements) != nil)
}

@Test func nodeWhoseAttributesFailIsSkippedWithItsSubtree() throws {
    let group = MockNode(role: "AXGroup", frame: CGRect(x: 10, y: 200, width: 200, height: 200), children: [
        button("Hidden2", frame: CGRect(x: 20, y: 220, width: 50, height: 30)),
    ])
    group.attributesFail = true
    let (app, _) = mailApp(content: [group, button("Visible", frame: CGRect(x: 300, y: 300, width: 50, height: 30))])
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(labelled("Hidden2", in: elements) == nil)
    #expect(labelled("Visible", in: elements) != nil)
}

@Test func axWindowWithoutAMatchingOnScreenWindowIsSkipped() throws {
    let (app, _) = mailApp(content: [button("Inbox button", frame: CGRect(x: 10, y: 10, width: 80, height: 30))])
    app.add(MockNode(role: "AXWindow", title: "Ghost", frame: CGRect(x: 2000, y: 0, width: 500, height: 500), children: [
        button("GhostButton", frame: CGRect(x: 2100, y: 50, width: 100, height: 30)),
    ]))
    let elements = try walkMail(MockAXQuerying(apps: [app]))

    #expect(labelled("GhostButton", in: elements) == nil)
    #expect(labelled("Inbox button", in: elements) != nil)
}

@Test func focusedElementIsMarkedFocused() throws {
    let save = button("Save", frame: CGRect(x: 10, y: 10, width: 80, height: 30))
    let cancel = button("Cancel", frame: CGRect(x: 100, y: 10, width: 80, height: 30))
    let (app, _) = mailApp(content: [save, cancel])
    let elements = try walkMail(MockAXQuerying(apps: [app], focusedNode: save))

    #expect(labelled("Save", in: elements)?.isFocused == true)
    #expect(labelled("Cancel", in: elements)?.isFocused == false)
}

@Test func shouldStopBeforeTheWalkEmitsNothing() throws {
    let (app, _) = mailApp(content: [button("Save", frame: CGRect(x: 10, y: 10, width: 80, height: 30))])
    let elements = try walkMail(MockAXQuerying(apps: [app]), shouldStop: { true })

    #expect(elements.isEmpty)
}

@Test func nodeCapStopsTheWalkAt2500Nodes() throws {
    // 8 groups of 375 buttons each: more than the 2500-node cap.
    let groups = (0..<8).map { groupIndex in
        MockNode(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 1000, height: 800), children: (0..<375).map { index in
            button("B\(groupIndex)-\(index)", frame: CGRect(x: CGFloat(index % 25) * 40, y: CGFloat(index / 25) * 10, width: 30, height: 8))
        })
    }
    let (app, _) = mailApp(content: groups)
    let elements = try walkMail(MockAXQuerying(apps: [app]))
    let buttons = elements.filter { $0.role == .button }

    // The window and 7 groups use 8 nodes plus 2492 buttons: 2500 visited in total.
    #expect(buttons.count <= AXEnumerator.maximumNodeCount)
    #expect(buttons.count == 2492)
    #expect(buttons.count < 3000)
}

@Test func unreadableApplicationThrows() {
    let app = MockNode(role: "AXApplication", title: "Mail", pid: 42)
    app.attributesFail = true
    #expect(throws: AXEnumerationError.applicationUnavailable(42)) {
        try walkMail(MockAXQuerying(apps: [app]))
    }
}
