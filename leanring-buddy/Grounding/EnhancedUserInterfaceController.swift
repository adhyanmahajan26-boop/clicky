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
//  Chrome builds its page tree ~2 s after the flag goes false → true, and
//  drops a write sent while it is launching, so after every write a
//  background follow-up polls for the page (rewriting once at 3 s) and
//  tells the coordinator when it shows up; asks check the page and wait at
//  most 0.6 s (see EnhancedUserInterfacePolicy, "Ask time").
//

import AppKit
import ClickyCore

final class EnhancedUserInterfaceController {
    private typealias WebContentActivation = EnhancedUserInterfacePolicy.WebContentActivation

    private let ax: AXQuerying
    private let axWriteQueue = DispatchQueue(label: "clicky.ax.enhancedUI", qos: .utility)
    private var currentlyEnhancedProcessIdentifier: pid_t?
    private var notificationObservers: [NSObjectProtocol] = []
    /// Per app with the flag: its write cycle / background follow-up state.
    private var activations: [pid_t: WebContentActivation] = [:]
    /// Background polls for an app's page after a flag write.
    private var followUpTasks: [pid_t: Task<Void, Never>] = [:]
    /// An app's page showed up in the tree in the background (main actor):
    /// the AX walk cache drops that app's toolbar-only walk.
    var onWebContentReady: ((pid_t, String) -> Void)?

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
            forget(disableProcessIdentifier)
        }
        let isElectron = ElectronDetection.isElectron(activatedApplication)
        let ax = ax
        axWriteQueue.async {
            if let disableProcessIdentifier = transition.disableProcessIdentifier {
                ax.setEnhancedUserInterface(false, for: ax.applicationNode(processIdentifier: disableProcessIdentifier))
            }
            if let enableProcessIdentifier = transition.enableProcessIdentifier {
                Self.writeFlag(ax: ax, processIdentifier: enableProcessIdentifier, isElectron: isElectron)
            }
        }
        if let enableProcessIdentifier = transition.enableProcessIdentifier {
            // Came forward (again): a new write cycle, and poll until its page
            // is in the tree. A write sent while the app is still launching is
            // lost; the follow-up writes once more after 3 s.
            var activation = WebContentActivation()
            activation.recordWrite(at: Date(), clearsBackoff: true)
            activations[enableProcessIdentifier] = activation
            startFollowUp(processIdentifier: enableProcessIdentifier, isElectron: isElectron,
                          applicationName: Self.name(of: activatedApplication))
        }
    }

    /// The flag false → true (so Chromium sees a change even when it thinks
    /// it is already on) plus AXManualAccessibility for Electron (Chrome
    /// ignores that one: measured, no web tree after 8 s). Runs on the
    /// write queue.
    nonisolated private static func writeFlag(ax: AXQuerying, processIdentifier: pid_t, isElectron: Bool) {
        let applicationNode = ax.applicationNode(processIdentifier: processIdentifier)
        ax.setEnhancedUserInterface(false, for: applicationNode)
        ax.setEnhancedUserInterface(true, for: applicationNode)
        if isElectron { ax.enableManualAccessibility(for: applicationNode) }
    }

    private func forget(_ processIdentifier: pid_t) {
        activations[processIdentifier] = nil
        followUpTasks[processIdentifier]?.cancel()
        followUpTasks[processIdentifier] = nil
    }

    private static func name(of application: NSRunningApplication) -> String {
        application.localizedName ?? application.bundleIdentifier ?? "pid \(application.processIdentifier)"
    }

    /// One look at the app's front window for its page (on the AX queue,
    /// after any pending writes).
    private func webContentState(of processIdentifier: pid_t, deadlineSeconds: TimeInterval) async -> EnhancedUserInterfacePolicy.WebContentState {
        let ax = ax
        return await withCheckedContinuation { continuation in
            axWriteQueue.async {
                let applicationNode = ax.applicationNode(processIdentifier: processIdentifier)
                continuation.resume(returning: EnhancedUserInterfacePolicy.webContentState(
                    ax: ax, applicationNode: applicationNode, deadline: Date().addingTimeInterval(deadlineSeconds)))
            }
        }
    }

    /// Polls (every 0.25 s, ≤ 7 s per write, one rewrite at 3 s) until the
    /// app's page is in the tree, then tells the coordinator so the next ask
    /// walks it afresh. Replaces the old "3 asks per pid, then never again".
    private func startFollowUp(processIdentifier: pid_t, isElectron: Bool, applicationName: String) {
        followUpTasks[processIdentifier]?.cancel()
        let startDate = Date()
        followUpTasks[processIdentifier] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state = await self.webContentState(of: processIdentifier, deadlineSeconds: 0.1)
                guard !Task.isCancelled, var activation = self.activations[processIdentifier] else { return }
                let step = activation.followUpStep(webContentState: state, at: Date())
                self.activations[processIdentifier] = activation
                switch step {
                case .ready:
                    self.followUpTasks[processIdentifier] = nil
                    let note = "\(applicationName) web content ready in the background after \(Int((Date().timeIntervalSince(startDate) * 1000).rounded())) ms"
                    print("🌐 \(note)")
                    self.onWebContentReady?(processIdentifier, note)
                    return
                case .gaveUp:
                    self.followUpTasks[processIdentifier] = nil
                    print("🌐 \(applicationName): no web content \(Int(WebContentActivation.followUpDuration)) s after the enhanced-UI write (\(state))\(activation.isBackedOff(at: Date()) ? "; backing off \(Int(WebContentActivation.backoffSeconds)) s" : "")")
                    return
                case .rewrite:
                    activation.recordWrite(at: Date(), isRewrite: true)
                    self.activations[processIdentifier] = activation
                    let ax = self.ax
                    self.axWriteQueue.async { Self.writeFlag(ax: ax, processIdentifier: processIdentifier, isElectron: isElectron) }
                    try? await Task.sleep(nanoseconds: UInt64(WebContentActivation.pollInterval * 1e9))
                case .poll(let seconds):
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1e9))
                }
            }
        }
    }

    /// What an ask-time check did, for the turn log and the AX cache.
    struct AskTimeResult {
        let processIdentifier: pid_t
        let applicationName: String
        let state: EnhancedUserInterfacePolicy.WebContentState
        let waitedMilliseconds: Int
        /// "set" (flag written now), "pending" (an earlier write is still
        /// being built), "backedOff" (no web content lately: no wait) or
        /// "ready" (first time the page is seen since the app came forward).
        let action: String

        /// The page is in the tree now but wasn't when the app's last walk
        /// may have been cached.
        var pageBecameReady: Bool { state == .ready }

        var note: String {
            "\(applicationName) enhancedUI at ask: \(action) → \(state) after \(waitedMilliseconds) ms"
        }
    }

    /// Called on every ask before the AX walks. When the frontmost listed
    /// Chromium/Electron app's page is already in the tree (the usual case)
    /// this returns nil after one quick look. Otherwise it writes the flag
    /// (unless a write is still being built), waits up to 0.6 s, and leaves a
    /// background follow-up polling so the next ask has the page. Returns a
    /// result also the first time the page is seen ready since the app came
    /// forward, so the caller drops the app's cached (toolbar-only) walk.
    func prepareFrontmostApplicationForAsk() async -> AskTimeResult? {
        guard let frontApplication = NSWorkspace.shared.frontmostApplication, frontApplication.processIdentifier != getpid() else { return nil }
        let processIdentifier = frontApplication.processIdentifier
        let isElectron = ElectronDetection.isElectron(frontApplication)
        guard EnhancedUserInterfacePolicy.matches(bundleIdentifier: frontApplication.bundleIdentifier, isElectron: isElectron,
                                                  configuredBundleIdentifiers: ClickySettings.enhancedUIBundleIDs) else { return nil }
        let applicationName = Self.name(of: frontApplication)
        var activation = activations[processIdentifier] ?? WebContentActivation()

        let initialState = await webContentState(of: processIdentifier, deadlineSeconds: 0.1)
        if initialState == .ready {
            let wasSeenReady = activation.lastReadyAt != nil
            activation.recordReady(at: Date())
            activations[processIdentifier] = activation
            followUpTasks[processIdentifier]?.cancel()
            followUpTasks[processIdentifier] = nil
            guard !wasSeenReady else { return nil }
            return AskTimeResult(processIdentifier: processIdentifier, applicationName: applicationName, state: .ready,
                                 waitedMilliseconds: 0, action: "ready")
        }

        // Another app (e.g. the other Chrome instance) holds the flag: hand it over.
        let previouslyEnhancedProcessIdentifier = currentlyEnhancedProcessIdentifier
        let disableProcessIdentifier = previouslyEnhancedProcessIdentifier != processIdentifier ? previouslyEnhancedProcessIdentifier : nil
        if let disableProcessIdentifier { forget(disableProcessIdentifier) }
        currentlyEnhancedProcessIdentifier = processIdentifier

        let now = Date()
        let writesNow = activation.shouldWriteAtAsk(at: now)
        let waitSeconds = activation.askWaitSeconds(at: now)
        let action = writesNow ? (waitSeconds == 0 ? "set (backedOff)" : "set") : (waitSeconds == 0 ? "backedOff" : "pending")
        if writesNow { activation.recordWrite(at: now) }
        activations[processIdentifier] = activation

        let ax = ax
        let waitResult: (state: EnhancedUserInterfacePolicy.WebContentState, waitedSeconds: TimeInterval) = await withCheckedContinuation { continuation in
            axWriteQueue.async {
                if let disableProcessIdentifier {
                    ax.setEnhancedUserInterface(false, for: ax.applicationNode(processIdentifier: disableProcessIdentifier))
                }
                if writesNow { Self.writeFlag(ax: ax, processIdentifier: processIdentifier, isElectron: isElectron) }
                let applicationNode = ax.applicationNode(processIdentifier: processIdentifier)
                continuation.resume(returning: EnhancedUserInterfacePolicy.waitForWebContent(ax: ax, applicationNode: applicationNode, timeout: waitSeconds) {
                    Thread.sleep(forTimeInterval: $0)
                })
            }
        }
        if waitResult.state == .ready {
            activations[processIdentifier]?.recordReady(at: Date())
            followUpTasks[processIdentifier]?.cancel()
            followUpTasks[processIdentifier] = nil
        } else if writesNow || followUpTasks[processIdentifier] == nil, activations[processIdentifier]?.isWritePending(at: Date()) == true {
            startFollowUp(processIdentifier: processIdentifier, isElectron: isElectron, applicationName: applicationName)
        }
        return AskTimeResult(processIdentifier: processIdentifier, applicationName: applicationName, state: waitResult.state,
                             waitedMilliseconds: Int((waitResult.waitedSeconds * 1000).rounded()), action: action)
    }

    /// Clicky is quitting: don't leave the flag on.
    private func restoreBeforeQuit() {
        guard let enhancedProcessIdentifier = currentlyEnhancedProcessIdentifier else { return }
        currentlyEnhancedProcessIdentifier = nil
        followUpTasks.values.forEach { $0.cancel() }
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
