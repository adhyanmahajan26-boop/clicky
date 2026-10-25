//
//  EnhancedUserInterfacePolicy.swift
//  ClickyCore
//
//  P6.8: Chromium browsers and Electron apps only build their full
//  accessibility tree when a client sets AXEnhancedUserInterface. Setting
//  it has side effects (window managers animate/position such windows
//  badly), so it is set only on listed apps and only while frontmost, and
//  set back to false when another app comes forward. The app side applies
//  the decisions; this is the pure part.
//

import Foundation

public enum EnhancedUserInterfacePolicy {
    /// In the bundle-id list: also match any detected Electron app.
    public static let electronToken = "electron"

    public static let defaultBundleIdentifiers = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", electronToken
    ]

    public static func matches(bundleIdentifier: String?, isElectron: Bool, configuredBundleIdentifiers: Set<String>) -> Bool {
        if isElectron && configuredBundleIdentifiers.contains(electronToken) { return true }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        return configuredBundleIdentifiers.contains(bundleIdentifier)
    }

    public struct ActivatedApplication: Sendable, Equatable {
        public let processIdentifier: pid_t
        public let bundleIdentifier: String?
        public let isElectron: Bool

        public init(processIdentifier: pid_t, bundleIdentifier: String?, isElectron: Bool) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.isElectron = isElectron
        }
    }

    public struct Transition: Sendable, Equatable {
        /// Set AXEnhancedUserInterface false on this app (no longer front).
        public var disableProcessIdentifier: pid_t?
        /// Set it true on this app (now front, listed).
        public var enableProcessIdentifier: pid_t?
        /// The app that has it set afterwards.
        public var enhancedProcessIdentifierAfter: pid_t?

        public init(disableProcessIdentifier: pid_t?, enableProcessIdentifier: pid_t?, enhancedProcessIdentifierAfter: pid_t?) {
            self.disableProcessIdentifier = disableProcessIdentifier
            self.enableProcessIdentifier = enableProcessIdentifier
            self.enhancedProcessIdentifierAfter = enhancedProcessIdentifierAfter
        }
    }

    /// What to do when `activated` comes forward. Clicky's own activation
    /// (its panel) changes nothing: the user is still looking at that app.
    public static func transition(currentlyEnhancedProcessIdentifier: pid_t?, activated: ActivatedApplication,
                                  ownProcessIdentifier: pid_t, configuredBundleIdentifiers: Set<String>) -> Transition {
        guard activated.processIdentifier != ownProcessIdentifier else {
            return Transition(disableProcessIdentifier: nil, enableProcessIdentifier: nil, enhancedProcessIdentifierAfter: currentlyEnhancedProcessIdentifier)
        }
        if activated.processIdentifier == currentlyEnhancedProcessIdentifier {
            return Transition(disableProcessIdentifier: nil, enableProcessIdentifier: nil, enhancedProcessIdentifierAfter: currentlyEnhancedProcessIdentifier)
        }
        let shouldEnable = matches(bundleIdentifier: activated.bundleIdentifier, isElectron: activated.isElectron,
                                   configuredBundleIdentifiers: configuredBundleIdentifiers)
        return Transition(disableProcessIdentifier: currentlyEnhancedProcessIdentifier,
                          enableProcessIdentifier: shouldEnable ? activated.processIdentifier : nil,
                          enhancedProcessIdentifierAfter: shouldEnable ? activated.processIdentifier : nil)
    }

    // MARK: - Ask time

    /// Setting the flag only when an app is activated misses cases seen live
    /// (turn 20261025-161216-42555df1: a second Chrome instance launched
    /// frontmost had no web content in its tree on the first ask): the
    /// write can land before the app is ready for it and its result isn't
    /// checked, the window can come forward without an activation change,
    /// and Chromium builds the web tree a moment after the flag is set. So
    /// on each ask the frontmost listed app is checked until its web
    /// content shows up once (up to `maximumAskAttempts` asks per pid).
    public static let maximumAskAttempts = 3
    public static let askTimeWaitSeconds = 0.25
    public static let askTimePollSeconds = 0.025

    public enum AskTimeAction: Sendable, Equatable {
        case none
        /// Set the flag (again) and wait up to `askTimeWaitSeconds` for web content.
        case enableAndWait
    }

    public static func askTimeAction(isListed: Bool, isVerified: Bool, attemptCount: Int) -> AskTimeAction {
        guard isListed, !isVerified, attemptCount < maximumAskAttempts else { return .none }
        return .enableAndWait
    }

    public enum WebContentState: Sendable, Equatable {
        /// An AXWebArea with children: the page is in the tree.
        case ready
        /// AXWebArea(s) without children yet.
        case emptyWebArea
        /// No AXWebArea in the front window (yet).
        case noWebArea
    }

    /// Searches the app's front window (breadth first, ≤ 12 levels, ≤ 600
    /// nodes) for an AXWebArea and whether it has children.
    public static func webContentState(ax: AXQuerying, applicationNode: AXNodeReference, deadline: Date? = nil,
                                       now: () -> Date = Date.init) -> WebContentState {
        guard let frontWindow = ax.windows(of: applicationNode).first else { return .noWebArea }
        var queue: [(node: AXNodeReference, depth: Int)] = [(frontWindow, 0)]
        var visitedCount = 0
        var sawEmptyWebArea = false
        while !queue.isEmpty, visitedCount < 600 {
            if let deadline, visitedCount % 16 == 0, now() >= deadline { break }
            let (node, depth) = queue.removeFirst()
            visitedCount += 1
            let children = ax.children(of: node, role: nil, limit: 64)
            if ax.attributes(of: node)?.role == "AXWebArea" {
                if !children.isEmpty { return .ready }
                sawEmptyWebArea = true
                continue
            }
            guard depth < 12 else { continue }
            queue += children.map { ($0, depth + 1) }
        }
        return sawEmptyWebArea ? .emptyWebArea : .noWebArea
    }

    /// Polls `webContentState` until ready or `timeout` (wall clock, so a
    /// slow AX tree can't stretch it much); `sleep` and `now` are injected
    /// (Thread.sleep / Date in the app). Returns the last state and the
    /// seconds waited.
    public static func waitForWebContent(ax: AXQuerying, applicationNode: AXNodeReference, timeout: TimeInterval = askTimeWaitSeconds,
                                         pollInterval: TimeInterval = askTimePollSeconds, now: () -> Date = Date.init,
                                         sleep: (TimeInterval) -> Void) -> (state: WebContentState, waitedSeconds: TimeInterval) {
        let start = now()
        let deadline = start.addingTimeInterval(timeout)
        var state = webContentState(ax: ax, applicationNode: applicationNode, deadline: deadline, now: now)
        while state != .ready, now().addingTimeInterval(pollInterval) <= deadline.addingTimeInterval(1e-9) {
            sleep(pollInterval)
            state = webContentState(ax: ax, applicationNode: applicationNode, deadline: deadline, now: now)
        }
        return (state, now().timeIntervalSince(start))
    }
}
