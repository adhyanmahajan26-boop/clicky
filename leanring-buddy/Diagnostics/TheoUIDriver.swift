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
import AVFoundation
import ClickyCore
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
        let ordered = NSApp.orderedWindows.filter { $0.isVisible && $0.level == .normal && $0.sheetParent == nil }
        if let top = ordered.first { return top }
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

    /// What's on top at a point in a window's coordinates: a sheet over the window when the point is on it. A window's
    /// screenshot includes its sheet, so tests work in the window's coordinates.
    static func target(_ window: NSWindow, at point: CGPoint) -> (NSWindow, CGPoint) {
        guard let sheet = window.attachedSheet else { return (window, point) }
        let onScreen = CGPoint(x: window.frame.minX + point.x, y: window.frame.maxY - point.y)
        guard sheet.frame.contains(onScreen) else { return (window, point) }
        return (sheet, CGPoint(x: onScreen.x - sheet.frame.minX, y: sheet.frame.maxY - onScreen.y))
    }

    /// Mouse down and up through the window, the way AppKit delivers a real click.
    static func click(_ topWindow: NSWindow, at topPoint: CGPoint, count: Int = 1) {
        let (window, point) = target(topWindow, at: topPoint)
        // A real click activates the app and makes its window key. The test profile stays inactive so the owner keeps
        // their focus, but the window takes key inside the app, or a text field couldn't take the click.
        if !window.isKeyWindow { window.makeKey() }
        hover(window, at: point)
        for clickNumber in 1...max(1, count) {
            // The mouse-up waits in the queue, the way a real one does: a control that tracks the mouse (an NSButton)
            // takes it from there while it handles the mouse-down.
            NSApp.postEvent(mouseEvent(.leftMouseUp, at: point, in: window, clickCount: clickNumber), atStart: false)
            NSApp.sendEvent(mouseEvent(.leftMouseDown, at: point, in: window, clickCount: clickNumber))
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

    /// Scrolls whatever scroll view is under the point. Positive `deltaY` moves the content up (further down the page).
    static func scroll(_ window: NSWindow, at point: CGPoint, deltaY: Int32) {
        var view = hitView(in: window, at: point)
        while let current = view, !(current is NSScrollView) { view = current.superview }
        guard let scrollView = view as? NSScrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maximumOffset = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        // Flipped documents grow downwards; the others count from the bottom.
        origin.y = document.isFlipped ? min(maximumOffset, max(0, origin.y + CGFloat(deltaY))) : min(maximumOffset, max(0, origin.y - CGFloat(deltaY)))
        clip.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// A click that opens a menu blocks in the menu's own run loop; this picks the item as soon as it opens.
    /// `rightClick`: a context menu.
    static func clickMenu(_ topWindow: NSWindow, at topPoint: CGPoint, choose item: String?, rightClick: Bool = false, completion: @escaping @MainActor ([String]) -> Void) {
        let (window, point) = target(topWindow, at: topPoint)
        // A SwiftUI Picker or Menu is a popup button: reach its menu directly, since an inactive app can't track a popup.
        if !rightClick, let popup = popUpButton(in: window, at: point) {
            // A SwiftUI Menu fills its items as it opens.
            if let menu = popup.menu {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.delegate?.menuWillOpen?(menu)
                menu.update()
            }
            let titles = popup.itemTitles
            if let item, let index = titles.firstIndex(where: { $0.lowercased() == item.lowercased() }) {
                popup.selectItem(at: index)
                _ = popup.sendAction(popup.action, to: popup.target)
                if let menuItem = popup.item(at: index), let action = menuItem.action, popup.action == nil {
                    NSApp.sendAction(action, to: menuItem.target, from: menuItem)
                }
            } else if let item, let found = popup.menu.flatMap({ Self.menuItem(named: item, in: $0) }), let action = found.action {
                // In a submenu, like "All folders".
                NSApp.sendAction(action, to: found.target, from: found)
            }
            if let menu = popup.menu { menu.delegate?.menuDidClose?(menu) }
            if titles.isEmpty, let menu = popup.menu {
                // Some only fill while they're really open: open it for a moment, read it, pick from it, close it.
                var shown: [String] = []
                let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: menu, queue: nil) { _ in
                    shown = menu.items.map(\.title)
                    RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                        MainActor.assumeIsolated {
                            if let item {
                                if let index = menu.items.firstIndex(where: { $0.title.lowercased() == item.lowercased() }) {
                                    menu.performActionForItem(at: index)
                                } else if let found = Self.menuItem(named: item, in: menu), let parent = found.menu, let index = parent.items.firstIndex(of: found) {
                                    parent.performActionForItem(at: index)
                                }
                            }
                            menu.cancelTracking()
                        }
                    }
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: popup.bounds.height), in: popup)
                NotificationCenter.default.removeObserver(observer)
                completion(shown)
                return
            }
            completion(titles)
            return
        }
        var titles: [String] = []
        var observer: NSObjectProtocol?
        observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu, menu.supermenu == nil else { return }
            // SwiftUI's context menu arrives as one untitled item holding the real menu.
            let shown = menu.items.count == 1 && menu.items[0].title.isEmpty ? (menu.items[0].submenu ?? menu) : menu
            titles = shown.items.map(\.title)
            RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                MainActor.assumeIsolated {
                    if let item, let index = shown.items.firstIndex(where: { $0.title.lowercased() == item.lowercased() }) {
                        shown.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
        }
        if rightClick {
            if !window.isKeyWindow { window.makeKey() }
            NSApp.postEvent(mouseEvent(.rightMouseUp, at: point, in: window), atStart: false)
            NSApp.sendEvent(mouseEvent(.rightMouseDown, at: point, in: window))
        } else {
            click(window, at: point)
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        completion(titles)
    }

    private static func menuItem(named name: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.title.lowercased() == name.lowercased() { return item }
            if let submenu = item.submenu, let found = menuItem(named: name, in: submenu) { return found }
        }
        return nil
    }

    private static func popUpButton(in window: NSWindow, at point: CGPoint) -> NSPopUpButton? {
        guard let content = window.contentView else { return nil }
        let inWindow = CGPoint(x: point.x, y: window.frame.height - point.y)
        let hit = content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
        var view = hit
        while let current = view {
            if let popup = current as? NSPopUpButton { return popup }
            view = current.superview
        }
        // SwiftUI can put the button beside the view that took the hit.
        return nil
    }

    static func key(_ topWindow: NSWindow, key: String, modifiers: [String]) {
        let window = topWindow.attachedSheet ?? topWindow
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
    static func typeText(_ text: String, in topWindow: NSWindow) -> Bool {
        let window = topWindow.attachedSheet ?? topWindow
        guard let responder = window.firstResponder as? NSTextInputClient else { return false }
        responder.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    static func state() -> [String: Any] {
        let window = NSApp.orderedWindows.first { $0.isVisible && $0.level == .normal && $0.sheetParent == nil }
        let responder = (window?.attachedSheet ?? window)?.firstResponder
        let isEditing = responder is NSTextView || responder is NSTextField
        return ["pane": String(describing: BotsSelection.shared.pane),
                "frontWindow": window?.title ?? "", "frontNumber": window?.windowNumber ?? 0,
                "sheet": window?.attachedSheet?.title ?? "", "firstResponder": responder.map { String(describing: Swift.type(of: $0)) } ?? "none",
                "editing": isEditing, "fieldLength": (responder as? NSText)?.string.count ?? 0, "responderClass": responder.map { String(describing: Swift.type(of: $0)) } ?? "",
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
        if handleVoiceCommand(name, command, respond: respond) { return true }
        guard name == "uiWindows" || name == "uiState" || name == "uiStopRun" || name == "uiPasteboard" || name == "uiMenus" || name == "uiMenuAction" || window(command) != nil else {
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
            for y in stride(from: 0, to: Int(target!.frame.height), by: max(1, step)) {
                for x in stride(from: 0, to: Int(target!.frame.width), by: max(1, step)) {
                    let point = CGPoint(x: x, y: y)
                    guard let hit = hitView(in: target!, at: point) else { continue }
                    let name = String(describing: Swift.type(of: hit))
                    var entry = byClass[name] ?? ["count": 0, "firstMouse": hit.acceptsFirstMouse(for: mouseEvent(.leftMouseDown, at: point, in: target!)), "example": ["x": x, "y": y]]
                    entry["count"] = (entry["count"] as? Int ?? 0) + 1
                    byClass[name] = entry
                }
            }
            respond(true, byClass, nil)
        case "uiMenus":
            // The app's menu bar: what ⌘C, ⌘V and the other shortcuts go through.
            let menus = (NSApp.mainMenu?.items ?? []).map { item -> [String: Any] in
                ["title": item.title, "items": (item.submenu?.items ?? []).map { sub in
                    ["title": sub.title, "key": sub.keyEquivalent, "action": sub.action.map { NSStringFromSelector($0) } ?? ""] as [String: Any]
                }]
            }
            respond(true, ["policy": NSApp.activationPolicy().rawValue, "menus": menus], nil)
        case "uiMenuAction":
            // Presses a menu item the way its shortcut would: {menu: "Edit", item: "Paste"}.
            let menu = NSApp.mainMenu?.items.first { $0.title == command["menu"] as? String }?.submenu
            guard let menu, let index = menu.items.firstIndex(where: { $0.title == command["item"] as? String }) else {
                respond(false, nil, "No such menu item.")
                return true
            }
            menu.update()
            let enabled = menu.items[index].isEnabled
            menu.performActionForItem(at: index)
            settle { respond(true, ["enabled": enabled, "state": state()], nil) }
        case "uiResponderAction":
            // Sends an action straight to the focused field: {action: "paste:"}. An inactive app has no key window for
            // the menu bar to reach, so this is how a test proves the field itself takes the paste.
            let responder = (target!.attachedSheet ?? target!).firstResponder
            let selector = NSSelectorFromString(command["action"] as? String ?? "")
            // Through the responder chain: sending straight to a responder that doesn't have the method would crash.
            let sent = NSApp.target(forAction: selector, to: responder, from: nil).map { NSApp.sendAction(selector, to: $0, from: nil) } ?? false
            settle { respond(sent, state(), sent ? nil : "Nothing handled it.") }
        case "uiPasteboard":
            // The test profile's own pasteboard (see TheoProfile): sets what ⌘V will paste.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command["text"] as? String ?? "", forType: .string)
            respond(true, ["pasteboard": NSPasteboard.general.name.rawValue], nil)
        case "uiStopRun":
            BotsStore.shared.stopRun(command["id"] as? String ?? "")
            respond(true, nil, nil)
        case "uiShowPanel":
            // The menu-bar panel, which has no icon to click in the test profile.
            NotificationCenter.default.post(name: .theoShowPanel, object: nil)
            settle { respond(true, windowList(), nil) }
        case "uiGo":
            // Straight to a pane, for setting up a screen: {pane: home|notes|connectors|routines|clicky|bot:<id>|group:<id>|category:<id>|settings:<section>}
            let pane = command["pane"] as? String ?? "home"
            let selection = BotsSelection.shared
            switch pane {
            case "home": selection.pane = .home
            case "notes": selection.pane = .notes
            case "connectors": selection.pane = .connectors
            case "routines": selection.pane = .routines
            case "clicky": selection.pane = .clicky
            case let value where value.hasPrefix("bot:"): selection.pane = .bot(String(value.dropFirst(4)))
            case let value where value.hasPrefix("group:"): selection.pane = .group(String(value.dropFirst(6)))
            case let value where value.hasPrefix("category:"): selection.pane = .category(String(value.dropFirst(9)))
            case let value where value.hasPrefix("settings:"):
                selection.openSettings(SettingsTab.Section(rawValue: String(value.dropFirst(9))) ?? .look)
            default: break
            }
            settle { respond(true, state(), nil) }
        case "uiCrew", "uiStudio", "uiSeedDemo", "uiSetDefaults", "uiLink", "uiBotPrompt":
            respond(true, CrewTestCommands.run(name, command, in: target), nil)
        case "uiHitMap": respond(true, hitMap(target!), nil)
        case "uiTree":
            let roles = (command["roles"] as? [String]).map(Set.init)
            respond(true, tree(target!, roles: roles), nil)
        case "uiPointer":
            // {on}: a pointer on screen that glides to each click, for recording the test profile. The real one stays put.
            DemoPointer.isOn = command["on"] as? Bool ?? true
            if !DemoPointer.isOn { DemoPointer.hide() }
            respond(true, ["on": DemoPointer.isOn], nil)
        case "uiGlide":
            let (window, at) = (target!, point())
            DemoPointer.glide(in: window, to: at) { respond(true, nil, nil) }
        case "uiClick":
            let (window, at, count) = (target!, point(), command["count"] as? Int ?? 1)
            DemoPointer.glide(in: window, to: at) {
                click(window, at: at, count: count)
                settle { respond(true, state(), nil) }
            }
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
            scroll(target!, at: point(), deltaY: Int32(command["dy"] as? Int ?? 200))
            settle { respond(true, state(), nil) }
        case "uiKey":
            key(target!, key: command["key"] as? String ?? "", modifiers: command["modifiers"] as? [String] ?? [])
            settle { respond(true, state(), nil) }
        case "uiType":
            let typed = typeText(command["text"] as? String ?? "", in: target!)
            settle { respond(typed, state(), typed ? nil : "Nothing has text focus.") }
        case "uiBots":
            // The sidebar's actions that a drag or a context menu does, by name:
            // {action: addCategory|move|pin|hide|leader|report|deleteCategory, item, section, name, on}.
            let store = BotsStore.shared
            let item = command["item"] as? String ?? ""
            let section = command["section"] as? String
            switch command["action"] as? String ?? "" {
            case "addCategory": respond(true, ["id": store.addSection(named: command["name"] as? String ?? "Test team") as Any], nil); return true
            case "move": store.move(item, toSection: section)
            case "pin": store.setPinned(command["on"] as? Bool ?? true, item)
            case "hide": store.setHidden(command["on"] as? Bool ?? true, item)
            case "leader": store.setLeader(command["bot"] as? String, of: section ?? "")
            case "hasManager": store.setHasManager(command["on"] as? Bool ?? true, of: section ?? "")
            case "report": store.reportToCEO(section ?? "")
            case "deleteCategory": store.deleteSection(section ?? "")
            default: break
            }
            let layout = store.layout
            respond(true, ["pinned": layout.pinned, "hidden": layout.hidden,
                           "sections": layout.sections.map { ["id": $0.id, "name": $0.name, "items": $0.items, "leader": $0.leaderID as Any? ?? NSNull()] as [String: Any] }], nil)
        case "uiMenuChoose", "uiRightClickChoose":
            clickMenu(target!, at: point(), choose: command["item"] as? String, rightClick: name == "uiRightClickChoose") { titles in
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

/// The pointer in recordings of the test profile, since its clicks don't move the real one.
@MainActor
enum DemoPointer {
    static var isOn = false
    private static var panel: NSPanel?

    static func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    static func glide(in window: NSWindow, to topPoint: CGPoint, then completion: @escaping @MainActor () -> Void) {
        guard isOn, let image = NSCursor.arrow.image.copy() as? NSImage else {
            completion()
            return
        }
        let size = NSSize(width: 26, height: 36)
        let tip = NSPoint(x: window.frame.minX + topPoint.x - 4, y: window.frame.maxY - topPoint.y - size.height + 4)
        let pointer = panel ?? {
            let start = NSRect(origin: NSPoint(x: tip.x + 120, y: tip.y - 90), size: size)
            let new = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            new.isOpaque = false
            new.backgroundColor = .clear
            new.hasShadow = false
            new.ignoresMouseEvents = true
            new.level = .popUpMenu
            image.size = size
            new.contentView = NSImageView(image: image)
            new.orderFrontRegardless()
            panel = new
            return new
        }()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pointer.animator().setFrameOrigin(tip)
        }, completionHandler: { Task { @MainActor in completion() } })
    }
}

// MARK: - Voice tests (test profile only: no mic, no real keys)

extension TheoUIDriver {
    /// uiDictationFeed {path, app?, window?, realTime?}: a sound file through dictation, typed into that app's window in the
    /// background. uiDictationStatus. uiDictationField {app, window}: what the field now says. uiDictationKeys {flags}: what the
    /// chord detector makes of these modifiers. uiDictationPill {state}: shows the pill for a screenshot. uiSet {key, value}.
    static func handleVoiceCommand(_ name: String, _ command: [String: Any], respond: @escaping @MainActor (Bool, Any?, String?) -> Void) -> Bool {
        switch name {
        case "uiSet":
            guard let key = command["key"] as? String else { respond(false, nil, "Needs key."); return true }
            UserDefaults.standard.set(command["value"], forKey: key)
            respond(true, ["key": key], nil)
        case "uiChatsList":
            // {harness, folder}: the chats the Chat menu would offer.
            guard let harness = command["harness"] as? String, let folder = command["folder"] as? String else { respond(false, nil, "Needs harness and folder."); return true }
            Task { @MainActor in
                let chats = await HarnessChats.list(harness: harness, folder: folder)
                respond(true, chats.map { ["id": $0.id, "title": $0.title, "age": HarnessChatText.age(of: $0.updatedAt)] }, nil)
            }
        case "uiRunFollowup":
            // {run, text}: what the box on a run's card does.
            guard let id = command["run"] as? String, let text = command["text"] as? String, let run = BotsStore.shared.t3Runs.first(where: { $0.id == id }) else { respond(false, nil, "Needs run and text."); return true }
            BotsStore.shared.sendFollowup(text, on: run)
            respond(true, ["sent": id], nil)
        case "uiRunStart":
            // {prompt, title, folder, harness, model, effort, room, mac, chat}: what Start on a run's card does, with the same choices.
            guard let prompt = command["prompt"] as? String, let title = command["title"] as? String else { respond(false, nil, "Needs prompt and title."); return true }
            let chat = (command["chat"] as? String).map { HarnessChatChoice(idOrTitle: $0) }
            BotsStore.shared.submitToT3(prompt: prompt, title: title, repo: (command["folder"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }, room: command["room"] as? String ?? BotsStore.teamID,
                                        harness: command["harness"] as? String, modelChoice: command["model"] as? String, effortChoice: command["effort"] as? String, macName: command["mac"] as? String, continuing: chat)
            respond(true, ["started": title], nil)
        case "uiPrismEval":
            guard let cases = command["cases"] as? String, let out = command["out"] as? String else { respond(false, nil, "Needs cases and out."); return true }
            Task { @MainActor in respond(true, await PrismEval.run(casesPath: cases, outPath: out), nil) }
        case "uiSarvamSocketCheck":
            Task { @MainActor in respond(true, await PrismEval.socketCheck(), nil) }
        case "uiSarvamLiveCheck":
            Task { @MainActor in respond(true, await PrismEval.liveCheck(), nil) }
        case "uiTestKey":
            // A throwaway key for the local stand-in server, in the test profile's own Keychain service.
            guard let provider = command["provider"] as? String else { respond(false, nil, "Needs provider."); return true }
            if let value = command["value"] as? String { ProviderKeychain.set(value, for: provider) } else { ProviderKeychain.delete(provider) }
            respond(true, ["hasKey": ProviderKeychain.get(provider) != nil], nil)
        case "uiSpeak":
            // Clicky's voice on a line, at zero volume; then uiSpeakStop says how long it took to go quiet.
            guard let manager = CompanionManager.current else { respond(false, nil, "No manager."); return true }
            CompanionSpeechOutput.isZeroVolumeForTests = true
            Task { @MainActor in
                try? await manager.speechOutputClient.speakText(command["text"] as? String ?? "Hello.")
                respond(true, ["engine": manager.speechOutputClient.currentEngineName], nil)
            }
        case "uiSpeakState":
            guard let manager = CompanionManager.current else { respond(false, nil, "No manager."); return true }
            respond(true, ["playing": manager.speechOutputClient.isPlaying, "engine": manager.speechOutputClient.currentEngineName], nil)
        case "uiSpeakStop":
            guard let manager = CompanionManager.current else { respond(false, nil, "No manager."); return true }
            let wasPlaying = manager.speechOutputClient.isPlaying
            let start = Date()
            manager.speechOutputClient.stopVoicesNow()
            respond(true, ["wasPlaying": wasPlaying, "playing": manager.speechOutputClient.isPlaying, "stopSeconds": Date().timeIntervalSince(start)], nil)
        case "uiCallStart":
            TheoCallController.start(activates: false)
            settle { respond(true, ["window": TheoCallController.windowNumber as Any? ?? NSNull()], nil) }
        case "uiCallStatus":
            respond(true, TheoCallController.session?.report() ?? [:], nil)
        case "uiCallMute":
            TheoCallController.session?.setMuted(command["on"] as? Bool ?? true)
            respond(true, [:], nil)
        case "uiCallEnd":
            TheoCallController.end()
            respond(true, [:], nil)
        case "uiCallFeed":
            guard let session = TheoCallController.session, let path = command["path"] as? String else { respond(false, nil, "Needs a call and a path."); return true }
            let silence = command["silence"] as? Double ?? 1.5
            Task { @MainActor in
                let fed = await session.feed(fileURL: URL(fileURLWithPath: path), trailingSilence: silence)
                respond(fed, session.report(), fed ? nil : "Can't read that file")
            }
        case "uiDictationStatus":
            guard let manager = CompanionManager.current else { respond(false, nil, "No manager."); return true }
            respond(true, manager.dictationController.statusReport(), nil)
        case "uiDictationKeys":
            let flags = (command["flags"] as? [String] ?? []).reduce(into: ChordModifiers()) { result, flag in
                switch flag {
                case "control": result.insert(.control)
                case "option": result.insert(.option)
                case "shift": result.insert(.shift)
                case "command": result.insert(.command)
                case "fn": result.insert(.function)
                default: break
                }
            }
            var detector = DictationChordDetector(required: DictationSettings.shortcut.modifiers)
            respond(true, ["transition": detector.flagsChanged(flags).map { String(describing: $0) } as Any? ?? NSNull()], nil)
        case "uiDictationField":
            guard let field = dictationField(command) else { respond(false, nil, "No such field."); return true }
            if command["toTheoScreen"] as? Bool == true, let screen = ClaudiaScreen.picked, let window = dictationWindow(command) {
                // Top-left origin, measured from the primary screen, for Accessibility.
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                var position = CGPoint(x: screen.visibleFrame.minX + 80, y: primaryHeight - screen.visibleFrame.maxY + 80)
                if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
            }
            respond(true, ["value": TypeForMeAccessibility.value(of: field.element) ?? "", "windowNumber": dictationWindowNumber(command) as Any? ?? NSNull()], nil)
        case "uiDictationPill":
            guard let manager = CompanionManager.current else { respond(false, nil, "No manager."); return true }
            manager.dictationController.showForTest(state: command["state"] as? String ?? "listening")
            settle { respond(true, ["window": manager.dictationController.pill.windowNumber as Any? ?? NSNull()], nil) }
        case "uiBrowserResearch":
            // {action: state|read|signedIn|askPermission|answer, url, accountWords, signedOutWords, answer, always, localHost}. Opens windows in the owner's real Chrome, on a
            // hidden screen. Only yes or no comes back about an account, and never a page's words except through read's count.
            let browser = BrowserResearcher.shared
            if let always = command["always"] as? Bool { UserDefaults.standard.set(always, forKey: "test.research.alwaysBrowser") }
            if let local = command["localHost"] as? Bool { browser.testAllowsLocalHost = local }
            switch command["action"] as? String ?? "state" {
            case "read":
                guard let url = (command["url"] as? String).flatMap(URL.init(string:)) else { respond(false, nil, "Needs url."); return true }
                Task { @MainActor in
                    switch await browser.read(url) {
                    case .page(let title, let text): respond(true, ["read": true, "hasTitle": title != nil, "characters": text.count, "state": browser.testState()], nil)
                    case .skipped(let reason): respond(true, ["read": false, "reason": reason, "state": browser.testState()], nil)
                    }
                }
            case "signedIn":
                guard let url = (command["url"] as? String).flatMap(URL.init(string:)) else { respond(false, nil, "Needs url."); return true }
                Task { @MainActor in
                    let found = await browser.testSignedIn(url, accountWords: command["accountWords"] as? [String] ?? [], signedOutWords: command["signedOutWords"] as? [String] ?? [])
                    respond(true, found, nil)
                }
            case "askPermission":
                // Brings up macOS's prompt on the owner's screen. Only when they've said they're ready.
                Task { @MainActor in
                    let answer = await browser.askForPermission()
                    respond(true, ["permission": answer.rawValue], nil)
                }
            case "answer":
                let done = command["answer"] as? String == "done"
                for id in browser.checks.keys { browser.answer(id, with: done ? .done : .skip) }
                respond(true, browser.testState(), nil)
            default:
                respond(true, browser.testState(), nil)
            }
        case "uiComposerDictation":
            // {action: state|toggle|stop|cancel|dismiss|feed|key|cursor|permissions|noMic, bot, path, realTime, stopAtEnd, key, up, at, microphone, speech}
            let dictation = ComposerDictation.shared
            let owner = command["bot"] as? String ?? dictation.ownerID ?? BotsStore.shared.primary?.id ?? ""
            switch command["action"] as? String ?? "state" {
            case "toggle": dictation.toggle(owner)
            case "stop": dictation.stop()
            case "cancel": dictation.cancel()
            case "dismiss": dictation.dismissNote()
            case "feed":
                guard let path = command["path"] as? String,
                      dictation.feed(fileURL: URL(fileURLWithPath: path), realTime: command["realTime"] as? Bool ?? true, stopAtEnd: command["stopAtEnd"] as? Bool ?? false) else {
                    respond(false, dictation.testReport(), "Needs a path, a readable file and dictation listening.")
                    return true
                }
            case "key":
                let taken = dictation.testKey(command["key"] as? String ?? "", isUp: command["up"] as? Bool ?? false)
                settle { respond(true, ["taken": taken].merging(dictation.testReport()) { first, _ in first }, nil) }
                return true
            case "cursor":
                guard dictation.testMoveCursor(command["at"] as? Int ?? 0) else { respond(false, nil, "The field isn't focused."); return true }
            case "readMicFormat":
                // What the no-mic guard would say on this Mac. Reads the format only: no tap, nothing started, and it
                // only looks if macOS has already said yes, so it can't bring up a prompt.
                guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                    respond(false, nil, "The microphone isn't already allowed, so this doesn't look.")
                    return true
                }
                let engine = AVAudioEngine()
                let node = engine.inputNode
                respond(true, ["usable": node.hasUsableMicFormat, "hardwareRate": node.inputFormat(forBus: 0).sampleRate,
                               "hardwareChannels": node.inputFormat(forBus: 0).channelCount, "engineRunning": engine.isRunning], nil)
                return true
            case "noMic":
                // Runs the real no-usable-mic path, stopping before any tap. Nothing is opened.
                dictation.testNoUsableMicrophone = command["on"] as? Bool ?? true
            case "permissions":
                dictation.testPermissions = ((command["microphone"] as? String).flatMap(ComposerDictationPermission.init(rawValue:)),
                                             (command["speech"] as? String).flatMap(ComposerDictationPermission.init(rawValue:)))
            default: break
            }
            settle { respond(true, dictation.testReport(), nil) }
        case "uiDictationFeed":
            guard let manager = CompanionManager.current, let path = command["path"] as? String else { respond(false, nil, "Needs path."); return true }
            var target = DictationInserter.Target.frontmost
            if command["app"] != nil {
                guard let field = dictationField(command) else { respond(false, nil, "No such field."); return true }
                target = .element(field.element, field.pid)
            } else {
                respond(false, nil, "A test needs a target app: it must not type into whatever the owner has open.")
                return true
            }
            let realTime = command["realTime"] as? Bool ?? true
            Task { @MainActor in
                let report = await manager.dictationController.feed(fileURL: URL(fileURLWithPath: path), target: target, realTime: realTime)
                respond(report.ok, report.result, report.error)
            }
        default:
            return false
        }
        return true
    }

    private static func dictationWindow(_ command: [String: Any]) -> AXUIElement? {
        guard let appName = command["app"] as? String,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else { return nil }
        let application = TypeForMeAccessibility.applicationElement(processIdentifier: app.processIdentifier)
        let windows = TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: application)
        let title = command["window"] as? String
        return windows.first { title == nil || TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0)?.contains(title!) == true }
    }

    /// The test window's number, for a screenshot of it alone.
    private static func dictationWindowNumber(_ command: [String: Any]) -> Int? {
        guard let appName = command["app"] as? String, let title = command["window"] as? String,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.first { ($0[kCGWindowOwnerName as String] as? String) == appName && ($0[kCGWindowName as String] as? String)?.contains(title) == true }?[kCGWindowNumber as String] as? Int
    }

    /// The text area in a named window of a named running app, read through Accessibility.
    private static func dictationField(_ command: [String: Any]) -> (element: AXUIElement, pid: pid_t)? {
        guard let appName = command["app"] as? String,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }),
              let window = dictationWindow(command) else { return nil }
        func search(_ element: AXUIElement, depth: Int) -> AXUIElement? {
            if TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element) == kAXTextAreaRole { return element }
            guard depth < 6 else { return nil }
            for child in TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element) {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(window, depth: 0).map { ($0, app.processIdentifier) }
    }
}
