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
