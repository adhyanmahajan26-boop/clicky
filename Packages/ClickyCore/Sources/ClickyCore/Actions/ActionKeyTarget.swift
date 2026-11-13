//
//  ActionKeyTarget.swift
//  ClickyCore
//
//  Which app a key step (Enter, a shortcut) goes to. It used to be whatever macOS called frontmost, so a
//  notification alert that popped up mid-task got the key (and its tier check), not the app the task was
//  working in (seen on the Studio, 2026-11-13: key steps attributed to UserNotificationCenter). Pure.
//

import Foundation

public enum ActionKeyTarget {
    /// System alert and notification agents that can be "frontmost" without being what the owner works in.
    public static let transientSystemBundleIdentifiers: Set<String> = [
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui"
    ]

    /// What's in front when the key step runs.
    public struct Frontmost: Equatable, Sendable {
        public var processIdentifier: Int32
        public var bundleIdentifier: String?
        /// It's Theo itself.
        public var isOwnApplication: Bool
        /// Theo's key window is one of its titled main windows (Home, Settings, Agents, Setup), not a panel.
        public var showsOwnMainWindow: Bool

        public init(processIdentifier: Int32, bundleIdentifier: String?, isOwnApplication: Bool = false, showsOwnMainWindow: Bool = false) {
            self.processIdentifier = processIdentifier
            self.bundleIdentifier = bundleIdentifier
            self.isOwnApplication = isOwnApplication
            self.showsOwnMainWindow = showsOwnMainWindow
        }
    }

    /// The app the key goes to: the app the task's previous step acted on (if it's still running) when what's in front
    /// is a system alert or notification, or one of Theo's own panels; otherwise the frontmost app. Theo's main window
    /// in front stays Theo, so the rule that a key there waits for a yes still applies.
    public static func processIdentifier(frontmost: Frontmost, previousTargetProcessIdentifier: Int32?, previousTargetIsRunning: Bool) -> Int32 {
        guard let previous = previousTargetProcessIdentifier, previousTargetIsRunning, previous != frontmost.processIdentifier else {
            return frontmost.processIdentifier
        }
        let isTransientSystemUI = frontmost.bundleIdentifier.map(transientSystemBundleIdentifiers.contains) ?? false
        let isOwnPanel = frontmost.isOwnApplication && !frontmost.showsOwnMainWindow
        return isTransientSystemUI || isOwnPanel ? previous : frontmost.processIdentifier
    }
}
