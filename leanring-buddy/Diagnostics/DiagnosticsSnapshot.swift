//
//  DiagnosticsSnapshot.swift
//  leanring-buddy
//
//  The values the Diagnostics window shows, as plain data so the view can be
//  rendered offscreen with fake values (no CompanionManager, no probes).
//  DiagnosticsProbes fills it in; nothing here runs a check by itself.
//

import Foundation

/// One labelled status row, e.g. "Accessibility: Granted".
struct DiagnosticsStatusLine: Equatable, Identifiable {
    enum Level: Equatable {
        /// Good news (granted, signed in, exit 0).
        case good
        /// Something the user needs to act on (denied, signed out, missing).
        case problem
        /// Not checked yet, or nothing recorded.
        case unknown
    }

    let label: String
    let value: String
    let level: Level

    var id: String { label }
}

/// A self-test button's last result. Only the pass/fail and the error text are kept.
struct DiagnosticsSelfTestResult: Equatable {
    let isPassing: Bool
    let summary: String
}

struct DiagnosticsSnapshot: Equatable {
    /// Read without asking the system for anything: the four permissions.
    var permissionLines: [DiagnosticsStatusLine] = []
    /// `claude auth status`, filled in when the user presses Check Claude.
    var claudeAuthLines: [DiagnosticsStatusLine] = [DiagnosticsStatusLine(label: "Claude sign-in", value: "Not checked. Press Check Claude.", level: .unknown)]
    /// The last code-mode preflight report, when code mode has run one this launch.
    var codeLines: [DiagnosticsStatusLine] = []
    /// `gh auth status` and the login, filled in when the user presses Check GitHub.
    var githubLines: [DiagnosticsStatusLine] = [DiagnosticsStatusLine(label: "GitHub", value: "Not checked. Press Check GitHub.", level: .unknown)]
    /// Qwen supervisor status, model id and the newest turn's time to first audio.
    var voiceLines: [DiagnosticsStatusLine] = []
    /// Whether ~/Library/LaunchAgents/local.clicky.tts.plist exists.
    var launchAgentLines: [DiagnosticsStatusLine] = []
    /// Last result per self-test name; a name without a result has not been run in this window.
    var selfTestResults: [String: DiagnosticsSelfTestResult] = [:]
}

/// The self-tests the window offers, in the order it lists them. Names are the ones
/// `Tools/clickyctl.sh` `selftest` takes; each one is run by the same static function
/// the debug inbox calls (DiagnosticsWindowController.runSelfTest).
enum DiagnosticsSelfTestCatalog {
    static let names: [String] = [
        "fixtureResolve", "verifyHitTest", "groundingLatency",
        "calibration", "overlayExclusion", "transportProbe", "tierProbe",
        "recheckExclusion", "markRoundTrip",
        "qwenCaptionSync"
    ]
}
