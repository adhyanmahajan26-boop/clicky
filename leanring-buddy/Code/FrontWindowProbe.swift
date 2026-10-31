//
//  FrontWindowProbe.swift
//  leanring-buddy
//
//  Read-only look at the frontmost window for "this repo": the front app's
//  bundle id, its focused window's AXTitle and AXDocument (Xcode's open
//  document, Terminal's working directory), and for Terminal the cwd of the
//  shell on the tty its title shows. Only Xcode, VS Code-style editors and
//  terminals are read (FrontWindowContext.isSupported); nothing is clicked,
//  typed or changed. FrontWindowRepoResolver (ClickyCore) does the rest.
//

import AppKit
import ApplicationServices
import ClickyCore

enum FrontWindowProbe {
    @MainActor
    static func capture() -> FrontWindowContext? {
        guard let frontApplication = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleIdentifier = frontApplication.bundleIdentifier
        // Clicky itself in front (e.g. its review panel): nothing to read.
        guard bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        guard FrontWindowContext.isSupported(bundleIdentifier: bundleIdentifier), AXIsProcessTrusted() else {
            return FrontWindowContext(bundleIdentifier: bundleIdentifier)
        }
        let applicationElement = AXUIElementCreateApplication(frontApplication.processIdentifier)
        AXUIElementSetMessagingTimeout(applicationElement, 0.5)
        var windowTitle: String?
        var documentURL: String?
        var focusedWindowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(applicationElement, kAXFocusedWindowAttribute as CFString, &focusedWindowValue) == .success,
           let focusedWindowValue, CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() {
            let windowElement = focusedWindowValue as! AXUIElement
            windowTitle = stringAttribute(kAXTitleAttribute, of: windowElement)
            documentURL = stringAttribute(kAXDocumentAttribute, of: windowElement)
        }
        var context = FrontWindowContext(bundleIdentifier: bundleIdentifier, windowTitle: windowTitle, documentURL: documentURL)
        if context.application == .terminal, let ttyName = FrontWindowRepoResolver.ttyName(fromTitle: windowTitle) {
            context.terminalWorkingDirectory = TerminalTTYLookup.workingDirectory(ttyName: ttyName)
        }
        return context
    }

    private static func stringAttribute(_ attributeName: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attributeName as CFString, &value) == .success else { return nil }
        if let stringValue = value as? String { return stringValue }
        if let urlValue = value as? URL { return urlValue.absoluteString }
        return nil
    }
}
