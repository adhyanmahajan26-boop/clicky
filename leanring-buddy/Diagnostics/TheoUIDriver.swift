//
//  TheoUIDriver.swift
//  leanring-buddy
//
//  Clicks and looks at Theo's own windows from inside the app, for the test profile only (the control inbox
//  refuses these commands otherwise). The clicks are real AppKit events sent through the window, so they go
//  through the same hit testing and first-click rules as a mouse, but the owner's pointer and focus never move.
//
//    uiWindows                         every window: number, title, frame, level, click-through, key
//    uiHitMap {window?}                what a mouse-down would hit across the window (other windows, other apps)
//    uiTree {window?, roles?}          the controls AppKit and SwiftUI expose, with frames and what a click there hits
//    uiClick {window?, x, y, count?}   mouse down and up at a point (window points, top left origin)
//    uiClickLabel {label, index?}      the same, at the control with that label
//    uiPress {label, index?}           the control's own accessibility press
//    uiHover {x, y}                    a mouse-moved event
//    uiScroll {x, y, dy}               a scroll-wheel event
//    uiKey {key, modifiers?}           key down and up to the window (and the menu bar for shortcuts)
//    uiType {text}                     typed into whatever has focus
//    uiPaste {text}                    puts text on a private pasteboard route: Paste into the focused field
//    uiMenuChoose {x, y, item}         clicks a menu control and picks an item from the menu it opens
//    uiState                           selected pane, sheets, focus
//

import AppKit
import SwiftUI

@MainActor
enum TheoUIDriver {
    // MARK: Windows

    static var theoWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible }
    }

    static func window(_ command: [String: Any]) -> NSWindow? {
        if let number = command["window"] as? Int { return NSApp.windows.first { $0.windowNumber == number } }
        if let title = command["windowTitle"] as? String { return theoWindows.first { $0.title == title } }
        // The frontmost titled window (a sheet above it counts).
        let ordered = NSApp.orderedWindows.filter { $0.isVisible && $0.level == .normal }
        if let top = ordered.first { return top.attachedSheet ?? top }
        return NSApp.keyWindow ?? theoWindows.first
    }

    static func windowList() -> [[String: Any]] {
        NSApp.windows.map { window in
            [
                "number": window.windowNumber, "title": window.title, "class": String(describing: Swift.type(of: window)),
                "visible": window.isVisible, "key": window.isKeyWindow, "main": window.isMainWindow, "level": window.level.rawValue,
                "ignoresMouse": window.ignoresMouseEvents, "alpha": window.alphaValue, "canKey": window.canBecomeKey,
                "frame": rect(window.frame), "contentView": window.contentView.map { String(describing: Swift.type(of: $0)) } ?? "none",
                "sheet": window.attachedSheet?.windowNumber ?? 0
            ] as [String: Any]
        }
    }

    /// Samples the window on a grid and asks the window server which window a mouse-down would land on.
    static func hitMap(_ window: NSWindow, step: CGFloat = 40) -> [String: Any] {
        var counts: [Int: Int] = [:]
        var firstMisses: [[String: Any]] = []
        var y = window.frame.minY + 6
        while y < window.frame.maxY - 6 {
            var x = window.frame.minX + 6
            while x < window.frame.maxX - 6 {
                let hit = NSWindow.windowNumber(at: NSPoint(x: x, y: y), belowWindowWithWindowNumber: 0)
                counts[hit, default: 0] += 1
                if hit != window.windowNumber, firstMisses.count < 12 {
                    firstMisses.append(["x": x - window.frame.minX, "y": window.frame.maxY - y, "hit": hit, "owner": owner(ofWindow: hit)])
                }
                x += step
            }
            y += step
        }
        return ["window": window.windowNumber, "samples": counts.values.reduce(0, +), "onTarget": counts[window.windowNumber] ?? 0,
                "byWindow": counts.map { ["window": $0.key, "count": $0.value, "owner": owner(ofWindow: $0.key)] as [String: Any] },
                "misses": firstMisses]
    }

    private static func owner(ofWindow number: Int) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]], let info = list.first else { return "?" }
        return "\(info[kCGWindowOwnerName as String] as? String ?? "?") pid \(info[kCGWindowOwnerPID as String] as? Int ?? 0) layer \(info[kCGWindowLayer as String] as? Int ?? 0)"
    }

    // MARK: The control tree

    struct Control {
        var role: String
        var label: String
        var value: String
        var enabled: Bool
        /// Window points, top left origin.
        var frame: CGRect
        var element: NSObject
    }

    /// Everything in the window's accessibility tree that has a role and a frame.
    static func controls(in window: NSWindow) -> [Control] {
        var found: [Control] = []
        guard let root = window.contentView else { return [] }
        walk(root, window: window, depth: 0, into: &found)
        return found
    }

    /// SwiftUI's accessibility nodes are private NSObject subclasses, so everything goes through selectors.
    private static func attribute(_ node: NSObject, _ name: String) -> Any? {
        guard node.responds(to: NSSelectorFromString(name)) else { return nil }
        return node.value(forKey: name)
    }

    private static func walk(_ element: Any, window: NSWindow, depth: Int, into found: inout [Control]) {
        guard depth < 48, let node = element as? NSObject else { return }
        let role = (attribute(node, "accessibilityRole") as? NSAccessibility.Role)?.rawValue ?? (attribute(node, "accessibilityRole") as? String) ?? ""
        let frameOnScreen = (attribute(node, "accessibilityFrame") as? NSValue)?.rectValue ?? .zero
        let title = label(of: node)
        if !role.isEmpty, frameOnScreen.width > 0, frameOnScreen.height > 0, role != "AXGroup" || !title.isEmpty {
            let frame = CGRect(x: frameOnScreen.minX - window.frame.minX, y: window.frame.maxY - frameOnScreen.maxY,
                               width: frameOnScreen.width, height: frameOnScreen.height)
            let enabled = (attribute(node, "isAccessibilityEnabled") as? Bool) ?? true
            found.append(Control(role: role, label: title, value: value(of: node), enabled: enabled, frame: frame, element: node))
        }
        var children = attribute(node, "accessibilityVisibleChildren") as? [Any] ?? []
        if children.isEmpty { children = attribute(node, "accessibilityChildren") as? [Any] ?? [] }
        for child in children { walk(child, window: window, depth: depth + 1, into: &found) }
    }

    private static func label(of node: NSObject) -> String {
        for name in ["accessibilityLabel", "accessibilityTitle", "accessibilityIdentifier"] {
            if let text = attribute(node, name) as? String, !text.isEmpty { return text }
        }
        return ""
    }

    private static func value(of node: NSObject) -> String {
        guard let value = attribute(node, "accessibilityValue") else { return "" }
        return String(String(describing: value).prefix(200))
    }

    static func tree(_ window: NSWindow, roles: Set<String>?) -> [[String: Any]] {
        controls(in: window).filter { roles == nil || roles!.contains($0.role) }.map { control in
            let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
            let hit = hitView(in: window, at: center)
            return ["role": control.role, "label": control.label, "value": control.value, "enabled": control.enabled,
                    "frame": rect(control.frame), "hitView": hit.map { String(describing: Swift.type(of: $0)) } ?? "none",
                    "firstMouse": hit.map { $0.acceptsFirstMouse(for: mouseEvent(.leftMouseDown, at: center, in: window)) } ?? false]
        }
    }

    private static func hitView(in window: NSWindow, at point: CGPoint) -> NSView? {
        guard let frameView = window.contentView?.superview else { return window.contentView?.hitTest(toAppKit(point, in: window)) }
        return frameView.hitTest(frameView.convert(toAppKit(point, in: window), from: nil))
    }

    private static func toAppKit(_ point: CGPoint, in window: NSWindow) -> NSPoint {
        NSPoint(x: point.x, y: window.frame.height - point.y)
    }

    static func find(_ label: String, index: Int, in window: NSWindow) -> Control? {
        let needle = label.lowercased()
        let matches = controls(in: window).filter { !$0.label.isEmpty && $0.label.lowercased().contains(needle) && $0.role != "AXStaticText" }
        let exact = matches.filter { $0.label.lowercased() == needle }
        let list = exact.isEmpty ? matches : exact
        return list.indices.contains(index) ? list[index] : nil
    }

    // MARK: Events

    private static var eventNumber = 1000

    private static func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow, clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: toAppKit(point, in: window), modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    static func hover(_ window: NSWindow, at point: CGPoint) {
        window.acceptsMouseMovedEvents = true
        window.sendEvent(mouseEvent(.mouseMoved, at: point, in: window))
    }

    /// Mouse down and up through the window, the way AppKit delivers a real click.
    static func click(_ window: NSWindow, at point: CGPoint, count: Int = 1) {
        hover(window, at: point)
        for clickNumber in 1...max(1, count) {
            window.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window, clickCount: clickNumber))
            window.sendEvent(mouseEvent(.leftMouseUp, at: point, in: window, clickCount: clickNumber))
        }
    }

    /// The truest click available without moving the pointer: Core Graphics events posted to this process, so
    /// they arrive through NSApplication's event queue like a real mouse, rather than straight at the window.
    static func postClick(_ window: NSWindow, at point: CGPoint) {
        let onScreen = window.convertPoint(toScreen: toAppKit(point, in: window))
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let location = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left) else { continue }
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            if type != .mouseMoved { event.setIntegerValueField(.mouseEventClickState, value: 1) }
            event.postToPid(getpid())
        }
    }

    static func scroll(_ window: NSWindow, at point: CGPoint, deltaY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: deltaY, wheel2: 0, wheel3: 0) else { return }
        let onScreen = window.convertPoint(toScreen: toAppKit(point, in: window))
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: onScreen.x, y: screenHeight - onScreen.y)
        guard let scrollEvent = NSEvent(cgEvent: event) else { return }
        window.sendEvent(scrollEvent)
    }

    /// A click that opens a menu blocks in the menu's own run loop; this picks the item as soon as it opens.
    static func clickMenu(_ window: NSWindow, at point: CGPoint, choose item: String?, completion: @escaping @MainActor ([String]) -> Void) {
        var titles: [String] = []
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
            titles = menu.items.map(\.title)
            RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                MainActor.assumeIsolated {
                    if let item, let index = menu.items.firstIndex(where: { $0.title.lowercased() == item.lowercased() }) {
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
        }
        click(window, at: point)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        completion(titles)
    }

    static func key(_ window: NSWindow, key: String, modifiers: [String]) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("cmd") { flags.insert(.command) }
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("option") { flags.insert(.option) }
        if modifiers.contains("ctrl") { flags.insert(.control) }
        let (characters, code) = keyInfo(key)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
        }
        guard let down = event(.keyDown), let up = event(.keyUp) else { return }
        // The same order AppKit uses: shortcuts go to the window and the main menu first.
        if flags.contains(.command) {
            if window.performKeyEquivalent(with: down) { return }
            if NSApp.mainMenu?.performKeyEquivalent(with: down) == true { return }
        }
        window.sendEvent(down)
        window.sendEvent(up)
    }

    private static func keyInfo(_ key: String) -> (String, UInt16) {
        switch key.lowercased() {
        case "return": return ("\r", 36)
        case "escape": return ("\u{1B}", 53)
        case "tab": return ("\t", 48)
        case "delete": return ("\u{7F}", 51)
        case "a": return ("a", 0)
        case "c": return ("c", 8)
        case "k": return ("k", 40)
        case "n": return ("n", 45)
        case "v": return ("v", 9)
        case "x": return ("x", 7)
        case ",": return (",", 43)
        default: return (key, 0)
        }
    }

    /// Types through the field editor, the same path as the keyboard (input method aside).
    static func typeText(_ text: String, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSTextInputClient else { return false }
        responder.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    static func state() -> [String: Any] {
        let window = NSApp.orderedWindows.first { $0.isVisible && $0.level == .normal }
        let responder = window?.firstResponder
        let isEditing = responder is NSTextView || responder is NSTextField
        return ["pane": String(describing: BotsSelection.shared.pane),
                "frontWindow": window?.title ?? "", "frontNumber": window?.windowNumber ?? 0,
                "sheet": window?.attachedSheet?.title ?? "", "firstResponder": responder.map { String(describing: Swift.type(of: $0)) } ?? "none",
                "editing": isEditing, "fieldText": (responder as? NSTextView)?.string.count ?? 0,
                "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", "isActive": NSApp.isActive]
    }

    private static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": Double(rect.minX), "y": Double(rect.minY), "w": Double(rect.width), "h": Double(rect.height)]
    }

    // MARK: Inbox

    /// Handles a ui* command. False when `name` isn't one.
    static func handle(_ name: String, _ command: [String: Any], respond: @escaping @MainActor (Bool, Any?, String?) -> Void) -> Bool {
        guard name.hasPrefix("ui") else { return false }
        guard TheoProfile.isTest else {
            respond(false, nil, "ui commands only work in the test profile.")
            return true
        }
        func point() -> CGPoint { CGPoint(x: (command["x"] as? Double) ?? Double(command["x"] as? Int ?? 0), y: (command["y"] as? Double) ?? Double(command["y"] as? Int ?? 0)) }
        guard name == "uiWindows" || name == "uiState" || window(command) != nil else {
            respond(false, nil, "No window.")
            return true
        }
        let target = window(command)
        switch name {
        case "uiWindows": respond(true, windowList(), nil)
        case "uiState": respond(true, state(), nil)
        case "uiFirstMouse":
            // Whether a click on a window of a background app would act, or only bring the window forward.
            var byClass: [String: [String: Any]] = [:]
            let step = command["step"] as? Int ?? 20
            for y in stride(from: 0, to: Int(target!.frame.height), by: step) {
                for x in stride(from: 0, to: Int(target!.frame.width), by: step) {
                    let point = CGPoint(x: x, y: y)
                    guard let hit = hitView(in: target!, at: point) else { continue }
                    let name = String(describing: Swift.type(of: hit))
                    var entry = byClass[name] ?? ["count": 0, "firstMouse": hit.acceptsFirstMouse(for: mouseEvent(.leftMouseDown, at: point, in: target!)), "example": ["x": x, "y": y]]
                    entry["count"] = (entry["count"] as? Int ?? 0) + 1
                    byClass[name] = entry
                }
            }
            respond(true, byClass, nil)
        case "uiDebugAX":
            let host = target!.contentView
            var info: [String: Any] = ["trusted": AXIsProcessTrusted(), "contentChildren": host?.accessibilityChildren()?.count ?? -1,
                                       "windowChildren": target!.accessibilityChildren()?.count ?? -1,
                                       "appChildren": NSApp.accessibilityChildren()?.count ?? -1,
                                       "contentRole": host?.accessibilityRole()?.rawValue ?? "nil",
                                       "subviews": host?.subviews.map { String(describing: Swift.type(of: $0)) } ?? []]
            info["childClasses"] = (host?.accessibilityChildren() ?? []).prefix(12).map { String(describing: Swift.type(of: $0)) }
            respond(true, info, nil)
        case "uiHitMap": respond(true, hitMap(target!), nil)
        case "uiTree":
            let roles = (command["roles"] as? [String]).map(Set.init)
            respond(true, tree(target!, roles: roles), nil)
        case "uiClick":
            click(target!, at: point(), count: command["count"] as? Int ?? 1)
            settle { respond(true, state(), nil) }
        case "uiClickPost":
            postClick(target!, at: point())
            settle { respond(true, state(), nil) }
        case "uiClickLabel", "uiPress":
            guard let label = command["label"] as? String, let control = find(label, index: command["index"] as? Int ?? 0, in: target!) else {
                respond(false, nil, "No control labelled \(command["label"] ?? "?")")
                return true
            }
            if name == "uiPress" {
                _ = control.element.perform(NSSelectorFromString("accessibilityPerformPress"))
            } else {
                click(target!, at: CGPoint(x: control.frame.midX, y: control.frame.midY))
            }
            settle { respond(true, ["control": rect(control.frame), "role": control.role, "state": state()], nil) }
        case "uiHover":
            hover(target!, at: point())
            settle { respond(true, state(), nil) }
        case "uiScroll":
            scroll(target!, at: point(), deltaY: Int32(command["dy"] as? Int ?? -200))
            settle { respond(true, state(), nil) }
        case "uiKey":
            key(target!, key: command["key"] as? String ?? "", modifiers: command["modifiers"] as? [String] ?? [])
            settle { respond(true, state(), nil) }
        case "uiType":
            let typed = typeText(command["text"] as? String ?? "", in: target!)
            settle { respond(typed, state(), typed ? nil : "Nothing has text focus.") }
        case "uiMenuChoose":
            clickMenu(target!, at: point(), choose: command["item"] as? String) { titles in
                settle { respond(true, ["items": titles, "state": state()], nil) }
            }
        default:
            respond(false, nil, "Unknown ui command \(name)")
        }
        return true
    }

    /// Gives SwiftUI a moment to apply what the event changed.
    private static func settle(_ then: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { then() } }
    }
}
