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
        "com.tinyspeck.slackmacgap", "com.microsoft.VSCode",
        // Spotify is built on Chromium (CEF), not Electron: without this its playlists and play buttons are hidden
        // from Clicky (3 elements on the Studio, 2026-11-13), so "play <playlist>" could never be pressed.
        "com.spotify.client",
        electronToken
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
    /// (turns 20261025-161216-42555df1, -165812-50f54d40: a frontmost Chrome
    /// had only its 15 toolbar elements on the first and second ask). Measured
    /// with a throwaway Chrome 155 and axfind (2026-10-25):
    ///  - a write sent while Chrome is still launching is lost: no AXWebArea
    ///    10 s later;
    ///  - AXManualAccessibility on the app element alone never builds the web
    ///    tree in Chrome (8 s+ polled), unlike Electron;
    ///  - AXEnhancedUserInterface false → true on a running Chrome builds it
    ///    after ~2.0 s (Chromium delays enabling, so window managers that
    ///    flip the flag around a window move don't switch accessibility on).
    /// The old 250 ms ask-time wait could never see it, and after three such
    /// asks per pid the check gave up for good. Now: every ask checks whether
    /// the page is in the tree (cheap); if not it (re)writes the flag (false
    /// → true, so Chromium sees a change) unless a write is still pending,
    /// waits up to `askTimeWaitSeconds`, and keeps polling in the background
    /// (`WebContentActivation`) so the next ask has the page. Apps whose
    /// window shows no web content after repeated tries are backed off for a
    /// while (time-based, not a per-pid ask count).
    public static let askTimeWaitSeconds = 0.6
    /// Until an app's page has been seen once, an ask waits up to this long
    /// after the write (Chrome 155 built its tree ~2.1 s after the flag; a
    /// live test pointed at another app's "Share" because it wasn't there yet).
    public static let firstPageWaitSeconds = 2.5
    public static let askTimePollSeconds = 0.025

    /// The background follow-up after a flag write, per app. Pure: the clock
    /// is passed in.
    public struct WebContentActivation: Sendable, Equatable {
        /// Measured Chromium delay between the flag and the page's tree.
        public static let chromiumEnableDelay: TimeInterval = 2.0
        /// Write again (false → true) once if nothing showed up by then.
        public static let rewriteAfter: TimeInterval = 3.0
        /// Background polling per write cycle.
        public static let followUpDuration: TimeInterval = 7.0
        public static let pollInterval: TimeInterval = 0.25
        /// Failed cycles in a row before the app is backed off.
        public static let failedCyclesBeforeBackoff = 2
        public static let backoffSeconds: TimeInterval = 60

        public enum FollowUpStep: Sendable, Equatable {
            /// The page is in the tree.
            case ready
            /// Check again after this many seconds.
            case poll(after: TimeInterval)
            /// Write the flag again (then `recordWrite(isRewrite: true)`).
            case rewrite
            /// Nothing this cycle; stop polling.
            case gaveUp
        }

        public private(set) var cycleStartedAt: Date?
        public private(set) var didRewrite = false
        public private(set) var failedCycles = 0
        public private(set) var backoffUntil: Date?
        public private(set) var lastReadyAt: Date?

        public init() {}

        /// A cycle is running: a write was sent less than `followUpDuration` ago.
        public func isWritePending(at now: Date) -> Bool {
            guard let cycleStartedAt else { return false }
            return now.timeIntervalSince(cycleStartedAt) < Self.followUpDuration
        }

        public func isBackedOff(at now: Date) -> Bool {
            backoffUntil.map { now < $0 } ?? false
        }

        /// At ask time the page wasn't in the tree: write the flag now?
        public func shouldWriteAtAsk(at now: Date) -> Bool {
            !isWritePending(at: now)
        }

        /// How long the ask waits for the page (0 while backed off).
        public func askWaitSeconds(at now: Date) -> TimeInterval {
            if isBackedOff(at: now) { return 0 }
            let usual = EnhancedUserInterfacePolicy.askTimeWaitSeconds
            // Only for an app whose page has never shown and hasn't already failed a cycle.
            guard lastReadyAt == nil, failedCycles == 0 else { return usual }
            // Never seen this app's page: wait out the tree build, measured from the write.
            let sinceWrite = cycleStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            return min(EnhancedUserInterfacePolicy.firstPageWaitSeconds, max(usual, EnhancedUserInterfacePolicy.firstPageWaitSeconds - sinceWrite))
        }

        /// A flag write was sent. A fresh write (activation, ask) starts a new
        /// cycle; an activation (`clearsBackoff`) also lifts a backoff.
        public mutating func recordWrite(at now: Date, isRewrite: Bool = false, clearsBackoff: Bool = false) {
            if clearsBackoff { backoffUntil = nil; failedCycles = 0 }
            if isRewrite {
                didRewrite = true
            } else {
                cycleStartedAt = now
                didRewrite = false
            }
        }

        /// The page was seen in the tree (at ask time or in the background).
        public mutating func recordReady(at now: Date) {
            cycleStartedAt = nil
            didRewrite = false
            failedCycles = 0
            backoffUntil = nil
            lastReadyAt = now
        }

        /// One background poll result → what to do next.
        public mutating func followUpStep(webContentState: WebContentState, at now: Date) -> FollowUpStep {
            if webContentState == .ready {
                recordReady(at: now)
                return .ready
            }
            guard let cycleStartedAt else { return .gaveUp }
            let elapsed = now.timeIntervalSince(cycleStartedAt)
            if elapsed >= Self.followUpDuration {
                self.cycleStartedAt = nil
                failedCycles += 1
                if failedCycles >= Self.failedCyclesBeforeBackoff {
                    backoffUntil = now.addingTimeInterval(Self.backoffSeconds)
                }
                return .gaveUp
            }
            if !didRewrite, elapsed >= Self.rewriteAfter { return .rewrite }
            return .poll(after: min(Self.pollInterval, Self.followUpDuration - elapsed))
        }
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
