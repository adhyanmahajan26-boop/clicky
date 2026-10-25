//
//  DiagnosticsWindowController.swift
//  leanring-buddy
//
//  Opens the Diagnostics window when the user presses its button in the
//  menu bar panel. Holds the snapshot model, runs the probes the user asked
//  for, and maps each self-test button to the same static function the debug
//  inbox's `selftest` command calls. Nothing opens or runs by itself.
//

import AppKit
import ClickyCore
import Combine
import SwiftUI

@MainActor
final class DiagnosticsModel: ObservableObject {
    @Published private(set) var snapshot = DiagnosticsSnapshot()
    private let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    /// The checks that only read local state: permissions, code preflight, voice, LaunchAgent.
    func refreshLocalChecks() {
        snapshot.permissionLines = DiagnosticsProbes.permissionLines()
        snapshot.codeLines = DiagnosticsProbes.codeLines(preflightReport: companionManager.codeModeController.preflightReport,
                                                         isCodeEnabled: ClickySettings.isCodeEnabled)
        let qwenServerSupervisor = companionManager.speechOutputClient.qwenServerSupervisor
        snapshot.voiceLines = DiagnosticsProbes.voiceLines(supervisorStatus: qwenServerSupervisor.status,
                                                           isSupervisorReady: qwenServerSupervisor.isReady,
                                                           modelIdentifier: companionManager.speechOutputClient.qwenLocalVoiceClient.modelIdentifier,
                                                           newestTimeToFirstAudioMilliseconds: DiagnosticsProbes.newestTimeToFirstAudioMilliseconds())
        snapshot.launchAgentLines = DiagnosticsProbes.launchAgentLines()
        snapshot.wakeLines = companionManager.wakeWordController.diagnosticsLines()
    }

    /// Runs `claude auth status`. Only from the Check Claude button.
    func checkClaude() {
        Task {
            snapshot.claudeAuthLines = await DiagnosticsProbes.claudeAuthLines()
        }
    }

    /// Runs `gh auth status` and `gh api user`. Only from the Check GitHub button.
    func checkGitHub() {
        Task {
            snapshot.githubLines = await DiagnosticsProbes.githubLines()
        }
    }

    /// Runs one self-test from its Run button and keeps its pass/fail line.
    func runSelfTest(named selfTestName: String) {
        Task {
            let (isPassing, selfTestResult) = await DiagnosticsWindowController.runSelfTest(named: selfTestName, companionManager: companionManager)
            let errorText = selfTestResult["error"] as? String
            let summary = errorText ?? "Fields: \(selfTestResult.keys.sorted().joined(separator: ", "))"
            snapshot.selfTestResults[selfTestName] = DiagnosticsSelfTestResult(isPassing: isPassing, summary: summary)
        }
    }
}

@MainActor
enum DiagnosticsWindowController {
    private static var window: NSWindow?
    private static var model: DiagnosticsModel?

    /// Shows the window (creating it once) and refreshes the local checks.
    static func show(companionManager: CompanionManager) {
        if model == nil {
            model = DiagnosticsModel(companionManager: companionManager)
        }
        guard let model else { return }
        model.refreshLocalChecks()

        if window == nil {
            let createdWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 760),
                                         styleMask: [.titled, .closable, .resizable],
                                         backing: .buffered, defer: false)
            createdWindow.title = "Clicky Diagnostics"
            // Closing hides the window; the model and its last results stay for the next open.
            createdWindow.isReleasedWhenClosed = false
            createdWindow.contentView = NSHostingView(rootView: DiagnosticsHostView(model: model))
            createdWindow.center()
            window = createdWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The same functions the debug inbox's `selftest` command runs, by name.
    static func runSelfTest(named selfTestName: String, companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        switch selfTestName {
        case "fixtureResolve", "verifyHitTest", "groundingLatency":
            return await GroundingSelfTests.run(named: selfTestName, mode: nil, companionManager: companionManager)
        case "calibration", "overlayExclusion", "transportProbe", "tierProbe":
            return await DiagnosticSelfTests.run(named: selfTestName, companionManager: companionManager)
        case "recheckExclusion", "markRoundTrip":
            return await MarkSelfTests.run(named: selfTestName, companionManager: companionManager)
        case "qwenCaptionSync":
            return await SpeechSelfTests.runQwenCaptionSync(companionManager: companionManager)
        default:
            return (false, ["error": "unknown selftest \(selfTestName)"])
        }
    }
}

/// Scrolls the panel view and rebuilds it whenever the model's snapshot changes.
private struct DiagnosticsHostView: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        ScrollView(.vertical) {
            DiagnosticsPanelView(
                snapshot: model.snapshot,
                actions: DiagnosticsActions(
                    checkClaude: { model.checkClaude() },
                    checkGitHub: { model.checkGitHub() },
                    runSelfTest: { selfTestName in model.runSelfTest(named: selfTestName) }
                )
            )
        }
    }
}
