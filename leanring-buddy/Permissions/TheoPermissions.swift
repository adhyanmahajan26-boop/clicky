//
//  TheoPermissions.swift
//  leanring-buddy
//
//  Accessibility and Screen Recording, the two privileges macOS grants in
//  System Settings. The first ask shows the system's own prompt; once that
//  has been shown this launch, asking again opens the right Settings page
//  instead (macOS won't prompt twice). Screen Recording only takes effect
//  after a relaunch, so a grant seen once is remembered.
//

import AppKit
import ApplicationServices

/// Where an ask for a privilege ended up.
enum PermissionAskOutcome: Equatable {
    case alreadyGranted
    case systemPrompt
    case systemSettings

    /// The pure rule: granted → nothing to do; never prompted → prompt; prompted already → Settings.
    static func next(isGranted: Bool, promptedThisLaunch: Bool) -> PermissionAskOutcome {
        if isGranted { return .alreadyGranted }
        return promptedThisLaunch ? .systemSettings : .systemPrompt
    }
}

enum TheoPermissions {
    private static var promptedAccessibility = false
    private static var promptedScreenRecording = false
    private static let screenRecordingSeenKey = "v2.permissions.screenRecordingSeen"

    // MARK: Accessibility

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func askForAccessibility() -> PermissionAskOutcome {
        let outcome = PermissionAskOutcome.next(isGranted: isAccessibilityGranted, promptedThisLaunch: promptedAccessibility)
        switch outcome {
        case .alreadyGranted: break
        case .systemPrompt:
            promptedAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .systemSettings:
            openSettingsPane("Privacy_Accessibility")
        }
        return outcome
    }

    static func openAccessibilitySettings() { openSettingsPane("Privacy_Accessibility") }

    // MARK: Screen Recording

    static var isScreenRecordingGranted: Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if granted { UserDefaults.standard.set(true, forKey: screenRecordingSeenKey) }
        return granted
    }

    /// Granted now, or granted before (it may just need a relaunch to apply).
    static var screenRecordingCountsAsGranted: Bool {
        isScreenRecordingGranted || UserDefaults.standard.bool(forKey: screenRecordingSeenKey)
    }

    static var askedForScreenRecordingThisLaunch: Bool { promptedScreenRecording }

    @discardableResult
    static func askForScreenRecording() -> PermissionAskOutcome {
        let outcome = PermissionAskOutcome.next(isGranted: isScreenRecordingGranted, promptedThisLaunch: promptedScreenRecording)
        switch outcome {
        case .alreadyGranted: break
        case .systemPrompt:
            promptedScreenRecording = true
            _ = CGRequestScreenCaptureAccess()
        case .systemSettings:
            openSettingsPane("Privacy_ScreenCapture")
        }
        return outcome
    }

    // MARK: Helpers

    /// Starts a fresh copy of Theo and quits this one (Screen Recording applies after this).
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Shows Theo.app in Finder (to drag it into the Privacy list).
    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
}
