//
//  BrowserTabTracker.swift
//  leanring-buddy
//
//  Clicky cleans up the browser tabs it opens. Each search / open_url step
//  remembers the tab it opened (the browser, and the tab's title once the
//  page has loaded). When Clicky opens its next one, its older tabs are
//  closed first, so a run of searches leaves one Clicky tab instead of a
//  pile; "close the tabs you opened" closes all of them. Tabs are closed
//  through the browser's own accessibility tree (the tab's close button,
//  no AppleScript, so no Automation prompt), and only a tab whose title
//  still matches what Clicky saw: one the owner has since navigated is left alone.
//

import AppKit
import ApplicationServices
import ClickyCore
import Foundation

@MainActor
final class BrowserTabTracker {
    static let shared = BrowserTabTracker()

    struct TrackedTab: Equatable {
        let processIdentifier: pid_t
        let title: String
        let openedAt: Date
    }

    private(set) var trackedTabs: [TrackedTab] = []

    /// Called right before Clicky opens a new tab: its earlier tabs go.
    func closeEarlierTabs() {
        let closedCount = closeTracked()
        if closedCount > 0 { print("🗂️ Closed \(closedCount) earlier Clicky tab(s)") }
    }

    /// Called after a search / open_url step: remembers the tab once its title settles.
    func noteOpenedTab(in browser: NSRunningApplication?, expectedHost: String?) {
        guard let browser else { return }
        let processIdentifier = browser.processIdentifier
        Task { @MainActor [weak self] in
            // The title is the page's once it has loaded; give it a few seconds.
            var lastTitle: String?
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let title = Self.selectedTabTitle(processIdentifier: processIdentifier), !title.isEmpty else { continue }
                if title == lastTitle, !Self.looksLikeLoading(title) { break }
                lastTitle = title
            }
            guard let self, let lastTitle, !Self.looksLikeLoading(lastTitle) else { return }
            self.trackedTabs.append(TrackedTab(processIdentifier: processIdentifier, title: Self.pageTitle(lastTitle), openedAt: Date()))
            print("🗂️ Tracking Clicky tab “\(lastTitle)”")
        }
    }

    /// "close the tabs you opened": every tracked tab still open. Returns how many closed.
    @discardableResult
    func closeTracked() -> Int {
        var closed = 0
        for tab in trackedTabs where Self.closeTab(titled: tab.title, processIdentifier: tab.processIdentifier) { closed += 1 }
        trackedTabs.removeAll()
        return closed
    }

    /// Tests: closes every tab whose title contains one of these pieces (the eval's own pages).
    @discardableResult
    func closeTabs(titleContaining pieces: [String], bundleIdentifier: String = "com.google.Chrome") -> Int {
        guard let browser = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return 0 }
        var closed = 0
        // Each close re-reads the tab strip (closing shifts the others).
        for tab in Self.tabs(processIdentifier: browser.processIdentifier).reversed() {
            guard let title = TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: tab),
                  pieces.contains(where: { title.localizedCaseInsensitiveContains($0) }) else { continue }
            if Self.pressCloseButton(of: tab) { closed += 1 }
        }
        return closed
    }

    // MARK: - Accessibility

    private static func looksLikeLoading(_ title: String) -> Bool {
        title.isEmpty || title == "New Tab" || title.hasPrefix("http") || title.lowercased() == "loading…"
    }

    /// Every tab button in the browser's windows (Chrome: AXTabGroup › AXRadioButton/AXTab).
    static func tabs(processIdentifier: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(processIdentifier)
        var found: [AXUIElement] = []
        for window in TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: application) {
            var queue: [(AXUIElement, Int)] = [(window, 0)]
            while !queue.isEmpty {
                let (element, depth) = queue.removeFirst()
                let role = TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: element)
                if role == "AXTabGroup" {
                    found += TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element).filter {
                        let childRole = TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: $0)
                        return childRole == "AXRadioButton" || childRole == "AXTab"
                    }
                    continue
                }
                // The tab strip is near the top of the tree; the web page is never searched.
                guard depth < 7, role != "AXWebArea" else { continue }
                queue += TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: element).map { ($0, depth + 1) }
            }
        }
        return found
    }

    static func selectedTabTitle(processIdentifier: pid_t) -> String? {
        for tab in tabs(processIdentifier: processIdentifier) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(tab, kAXValueAttribute as CFString, &value) == .success,
               (value as? NSNumber)?.boolValue == true {
                return TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: tab)
            }
        }
        return nil
    }

    static func closeTab(titled title: String, processIdentifier: pid_t) -> Bool {
        guard let tab = tabs(processIdentifier: processIdentifier).first(where: {
            pageTitle(TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: $0) ?? "") == pageTitle(title)
        }) else {
            return false
        }
        return pressCloseButton(of: tab)
    }

    /// Chrome adds " - Memory usage - 197 MB" (and similar) to tab titles; compare the page title only.
    static func pageTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #" - (Memory usage|Audio playing|Network error).*$"#, with: "", options: .regularExpression)
    }

    /// The tab's own × button (AXButton "Close"); never a key press, so the wrong tab can't close.
    /// Chrome only exposes the × of the selected tab, so a background tab is selected first.
    static func pressCloseButton(of tab: AXUIElement) -> Bool {
        if pressVisibleCloseButton(of: tab) { return true }
        guard AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success else { return false }
        for _ in 0..<10 {
            usleep(30_000)
            if pressVisibleCloseButton(of: tab) { return true }
        }
        return false
    }

    private static func pressVisibleCloseButton(of tab: AXUIElement) -> Bool {
        for child in TypeForMeAccessibility.elementArrayAttribute(kAXChildrenAttribute, of: tab)
        where TypeForMeAccessibility.stringAttribute(kAXRoleAttribute, of: child) == "AXButton" {
            let label = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { TypeForMeAccessibility.stringAttribute($0, of: child) }.joined(separator: " ")
            if label.localizedCaseInsensitiveContains("close") {
                return AXUIElementPerformAction(child, kAXPressAction as CFString) == .success
            }
        }
        return false
    }
}
