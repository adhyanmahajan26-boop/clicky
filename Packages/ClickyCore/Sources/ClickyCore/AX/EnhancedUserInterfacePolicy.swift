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
}
