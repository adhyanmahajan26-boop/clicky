//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Analytics are disabled in this personal build — nothing leaves the Mac.
//  The call sites are kept so upstream code still compiles unchanged; every
//  method here is intentionally a no-op.
//

import Foundation

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {}

    // MARK: - App Lifecycle

    static func trackAppOpened() {}

    // MARK: - Onboarding

    static func trackOnboardingStarted() {}

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - Errors

    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}
