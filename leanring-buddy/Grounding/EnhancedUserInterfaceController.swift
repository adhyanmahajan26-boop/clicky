//
//  EnhancedUserInterfaceController.swift
//  leanring-buddy
//
//  P6.8: sets AXEnhancedUserInterface on the frontmost app when it's a
//  listed Chromium/Electron app (`v2.grounding.enhancedUIBundleIDs`) so its
//  full AX tree is there by the time the user asks, and sets it back to
//  false when another app comes forward and when Clicky quits (the flag
//  upsets window managers). Electron apps also get AXManualAccessibility,
//  as the walk already does. AX writes are IPC: they run on a background
//  queue, never the main thread. Decisions: EnhancedUserInterfacePolicy.
//

import AppKit
import ClickyCore

final class EnhancedUserInterfaceController {
    private let ax: AXQuerying
    private let axWriteQueue = DispatchQueue(label: "clicky.ax.enhancedUI", qos: .utility)
    private var currentlyEnhancedProcessIdentifier: pid_t?
    private var notificationObservers: [NSObjectProtocol] = []
    /// Apps whose web content was seen in the tree since they came forward.
    private var verifiedProcessIdentifiers: Set<pid_t> = []
    /// Ask-time attempts per app since it came forward.
    private var askAttemptCounts: [pid_t: Int] = [:]

    init(ax: AXQuerying) {
        self.ax = ax
    }

    /// Starts following the frontmost app (idempotent).
    func start() {
        guard notificationObservers.isEmpty else { return }
        notificationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let activatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontmostApplicationChanged(to: activatedApplication) }
        })
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreBeforeQuit() }
        })
        frontmostApplicationChanged(to: NSWorkspace.shared.frontmostApplication)
    }

    private func frontmostApplicationChanged(to activatedApplication: NSRunningApplication?) {
        guard let activatedApplication else { return }
        let transition = EnhancedUserInterfacePolicy.transition(
            currentlyEnhancedProcessIdentifier: currentlyEnhancedProcessIdentifier,
            activated: .init(processIdentifier: activatedApplication.processIdentifier, bundleIdentifier: activatedApplication.bundleIdentifier,
                             isElectron: ElectronDetection.isElectron(activatedApplication)),
            ownProcessIdentifier: getpid(),
            configuredBundleIdentifiers: ClickySettings.enhancedUIBundleIDs
        )
        currentlyEnhancedProcessIdentifier = transition.enhancedProcessIdentifierAfter
        if let disableProcessIdentifier = transition.disableProcessIdentifier {
            verifiedProcessIdentifiers.remove(disableProcessIdentifier)
            askAttemptCounts[disableProcessIdentifier] = nil
        }
        if let enableProcessIdentifier = transition.enableProcessIdentifier {
            // Came forward again: check its tree on the next ask.
            verifiedProcessIdentifiers.remove(enableProcessIdentifier)
            askAttemptCounts[enableProcessIdentifier] = nil
        }
        let isElectron = ElectronDetection.isElectron(activatedApplication)
        let ax = ax
        axWriteQueue.async {
            if let disableProcessIdentifier = transition.disableProcessIdentifier {
                ax.setEnhancedUserInterface(false, for: ax.applicationNode(processIdentifier: disableProcessIdentifier))
            }
            if let enableProcessIdentifier = transition.enableProcessIdentifier {
                let applicationNode = ax.applicationNode(processIdentifier: enableProcessIdentifier)
                ax.setEnhancedUserInterface(true, for: applicationNode)
                if isElectron { ax.enableManualAccessibility(for: applicationNode) }
            }
        }
    }

    /// What an ask-time check did, for the turn log and the AX cache.
    struct AskTimeResult {
        let processIdentifier: pid_t
        let applicationName: String
        let state: EnhancedUserInterfacePolicy.WebContentState
        let waitedMilliseconds: Int
        let wasAlreadyOn: Bool

        var note: String {
            "\(applicationName) enhancedUI at ask: \(wasAlreadyOn ? "on" : "set") → \(state) after \(waitedMilliseconds) ms"
        }
    }

    /// Called on every ask before the AX walks: makes sure the frontmost
    /// listed Chromium/Electron app really has AXEnhancedUserInterface and
    /// its page in the tree. The activation-time write can be lost (sent
    /// while the app was still launching, result unchecked), a window can
    /// come forward without an activation change, and Chromium builds the
    /// web tree only after the flag is set. So until the app's web content
    /// has been seen once (≤ 3 asks), set the flag for the frontmost pid
    /// and wait up to 250 ms for an AXWebArea with children. Nil when
    /// nothing was done (the usual case: already verified).
    func prepareFrontmostApplicationForAsk() async -> AskTimeResult? {
        guard let frontApplication = NSWorkspace.shared.frontmostApplication, frontApplication.processIdentifier != getpid() else { return nil }
        let processIdentifier = frontApplication.processIdentifier
        let isElectron = ElectronDetection.isElectron(frontApplication)
        let isListed = EnhancedUserInterfacePolicy.matches(bundleIdentifier: frontApplication.bundleIdentifier, isElectron: isElectron,
                                                           configuredBundleIdentifiers: ClickySettings.enhancedUIBundleIDs)
        let action = EnhancedUserInterfacePolicy.askTimeAction(isListed: isListed, isVerified: verifiedProcessIdentifiers.contains(processIdentifier),
                                                               attemptCount: askAttemptCounts[processIdentifier] ?? 0)
        guard action == .enableAndWait else { return nil }
        askAttemptCounts[processIdentifier, default: 0] += 1

        // Another app (e.g. the other Chrome instance) holds the flag: hand it over.
        let previouslyEnhancedProcessIdentifier = currentlyEnhancedProcessIdentifier
        let disableProcessIdentifier = previouslyEnhancedProcessIdentifier != processIdentifier ? previouslyEnhancedProcessIdentifier : nil
        if let disableProcessIdentifier { verifiedProcessIdentifiers.remove(disableProcessIdentifier) }
        currentlyEnhancedProcessIdentifier = processIdentifier

        let ax = ax
        let applicationName = frontApplication.localizedName ?? frontApplication.bundleIdentifier ?? "pid \(processIdentifier)"
        let result: AskTimeResult = await withCheckedContinuation { continuation in
            axWriteQueue.async {
                if let disableProcessIdentifier {
                    ax.setEnhancedUserInterface(false, for: ax.applicationNode(processIdentifier: disableProcessIdentifier))
                }
                let applicationNode = ax.applicationNode(processIdentifier: processIdentifier)
                let wasAlreadyOn = ax.enhancedUserInterface(of: applicationNode) == true
                if wasAlreadyOn, EnhancedUserInterfacePolicy.webContentState(ax: ax, applicationNode: applicationNode,
                                                                            deadline: Date().addingTimeInterval(0.1)) == .ready {
                    continuation.resume(returning: AskTimeResult(processIdentifier: processIdentifier, applicationName: applicationName,
                                                                 state: .ready, waitedMilliseconds: 0, wasAlreadyOn: true))
                    return
                }
                ax.setEnhancedUserInterface(true, for: applicationNode)
                if isElectron { ax.enableManualAccessibility(for: applicationNode) }
                let waitResult = EnhancedUserInterfacePolicy.waitForWebContent(ax: ax, applicationNode: applicationNode) { Thread.sleep(forTimeInterval: $0) }
                continuation.resume(returning: AskTimeResult(processIdentifier: processIdentifier, applicationName: applicationName,
                                                             state: waitResult.state, waitedMilliseconds: Int((waitResult.waitedSeconds * 1000).rounded()),
                                                             wasAlreadyOn: wasAlreadyOn))
            }
        }
        if result.state == .ready { verifiedProcessIdentifiers.insert(processIdentifier) }
        return result
    }

    /// Clicky is quitting: don't leave the flag on.
    private func restoreBeforeQuit() {
        guard let enhancedProcessIdentifier = currentlyEnhancedProcessIdentifier else { return }
        currentlyEnhancedProcessIdentifier = nil
        let ax = ax
        // Short and bounded (0.25 s AX timeout): the app is about to exit.
        axWriteQueue.sync {
            ax.setEnhancedUserInterface(false, for: ax.applicationNode(processIdentifier: enhancedProcessIdentifier))
        }
    }
}

/// Electron apps ship the Electron framework inside their bundle.
enum ElectronDetection {
    static func isElectron(_ application: NSRunningApplication) -> Bool {
        application.bundleURL.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
        } ?? false
    }
}
