//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import ClickyCore
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""
    /// True once Screen Recording was requested this launch: the grant only
    /// applies after a relaunch, so the row swaps Grant for Relaunch.
    @State private var isScreenRecordingRelaunchOffered = WindowPositionManager.hasRequestedScreenRecordingDuringCurrentLaunch

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                CompanionVoicePickerRow(
                    speechOutput: companionManager.speechOutputClient,
                    systemVoiceClient: companionManager.speechOutputClient.systemVoiceClient,
                    qwenServerSupervisor: companionManager.speechOutputClient.qwenServerSupervisor,
                    openVoiceGallery: {
                        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                        companionManager.voiceGalleryController.showWindow(activatesClicky: true)
                    }
                )
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                handsFreeSessionButton
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                WakeWordSettingsRow(wakeWordController: companionManager.wakeWordController)
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                copyLastAnswerButton
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Clicky toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showClickyCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                claudeCodeConnectionButton
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                silentModeToggleRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 8)

                CodeModeSettingsRow(codeModeController: companionManager.codeModeController)
                    .padding(.horizontal, 16)
            }

            #if DEBUG
            Spacer()
                .frame(height: 12)

            companionPreviewDebugRow
                .padding(.horizontal, 16)
            #endif

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk. Double-tap it for hands-free.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your personal Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Runs on your Claude subscription through Claude Code. No API keys, no tracking.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Clicky only takes a screenshot while you hold the hotkey. Screenshots go to Claude through Claude Code and are not saved.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Accessibility")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    if !isGranted {
                        staleSettingsEntryHint
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    if isGranted {
                        Text("Only takes a screenshot when you use the hotkey")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else if isScreenRecordingRelaunchOffered {
                        Text("Turned it on? Relaunch to apply it.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    } else {
                        staleSettingsEntryHint
                    }
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else if isScreenRecordingRelaunchOffered {
                Button(action: {
                    // macOS only applies Screen Recording to a fresh launch.
                    WindowPositionManager.relaunchApp()
                }) {
                    Text("Relaunch")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts. Either way it only applies after a
                    // relaunch, so offer that next.
                    WindowPositionManager.requestScreenRecordingPermission()
                    isScreenRecordingRelaunchOffered = true
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    /// Shown under a missing Accessibility / Screen Recording permission. When
    /// Clicky's signature changes, System Settings can still show an old Clicky
    /// entry switched on that no longer applies to this build.
    private var staleSettingsEntryHint: some View {
        Text("Already on in Settings? Select Clicky, press −, then add it again.")
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Silent Mode Toggle

    private var silentModeToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: companionManager.isSilentModeEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Silent mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Text("Listens and answers on screen, never speaks")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isSilentModeEnabled },
                set: { companionManager.setSilentModeEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Haiku", modelID: ClickyModels.haiku)
                modelOptionButton(label: "Sonnet", modelID: ClickyModels.sonnet)
                modelOptionButton(label: "Opus", modelID: ClickyModels.opus)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Companion Preview (Debug)

    #if DEBUG
    /// Debug-only controls that drive the simulated activity source, so the
    /// spark's thinking spin and 0–4 orbiting workers can be tried before a
    /// real source is connected.
    private var companionPreviewDebugRow: some View {
        HStack(spacing: 8) {
            Text("Companion")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            companionPreviewThinkingToggleButton

            HStack(spacing: 0) {
                ForEach(0...CompanionActivityLimits.maximumVisibleWorkers, id: \.self) { simulatedWorkerCount in
                    companionPreviewWorkerCountButton(simulatedWorkerCount: simulatedWorkerCount)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private var companionPreviewThinkingToggleButton: some View {
        let isSimulatingThinking = companionManager.isCompanionCoordinatorThinking
        return Button(action: {
            companionManager.simulatedCompanionActivitySource.setSimulatedCoordinatorThinking(!isSimulatingThinking)
        }) {
            Text("Think")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSimulatingThinking ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSimulatingThinking ? DS.Colors.overlayCompanionOrange.opacity(0.35) : Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func companionPreviewWorkerCountButton(simulatedWorkerCount: Int) -> some View {
        let isSelected = companionManager.visibleCompanionWorkers.count == simulatedWorkerCount
        return Button(action: {
            companionManager.simulatedCompanionActivitySource.setSimulatedWorkingWorkerCount(simulatedWorkerCount)
        }) {
            Text("\(simulatedWorkerCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
    #endif

    // MARK: - Hands-Free Session

    /// Starts or ends the always-listening session. Same as double-tapping
    /// Control+Option, for when the user would rather click.
    private var handsFreeSessionButton: some View {
        Button(action: {
            companionManager.toggleHandsFreeSession()
        }) {
            HStack(spacing: 8) {
                Image(systemName: companionManager.isHandsFreeSessionActive ? "stop.circle.fill" : "waveform.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(companionManager.isHandsFreeSessionActive ? DS.Colors.destructiveText : DS.Colors.accentText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(companionManager.isHandsFreeSessionActive ? "End hands-free session" : "Start hands-free session")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Just talk. Say “wait”, “capture”, or “done”.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// Copies the last spoken answer (also: say "copy that").
    private var copyLastAnswerButton: some View {
        Button(action: {
            companionManager.copyLastAnswerToPasteboard()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
                Text("Copy last answer")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("or say “copy that”")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(companionManager.lastAnswerText == nil ? DS.Colors.textTertiary : DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(companionManager.lastAnswerText == nil)
    }

    // MARK: - Claude Code Connection

    /// Shows whether the Claude Code CLI is signed in to the user's Claude
    /// subscription. Clicking re-checks, so after running `claude auth login`
    /// in Terminal the user can confirm without restarting the app.
    private var claudeCodeConnectionButton: some View {
        Button(action: {
            companionManager.refreshClaudeCodeSignInStatus()
            if !companionManager.isClaudeCodeSignedIn { openSetupWindow() }
        }) {
            HStack(spacing: 8) {
                Image(systemName: companionManager.isClaudeCodeSignedIn ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(companionManager.isClaudeCodeSignedIn ? DS.Colors.success : DS.Colors.warning)

                VStack(alignment: .leading, spacing: 2) {
                    Text(companionManager.isClaudeCodeSignedIn
                         ? (ClickySettings.brainAuthMode == .apiKey ? "Claude API key connected" : "Claude subscription connected")
                         : "Claude isn't connected")
                        .font(.system(size: 12, weight: .semibold))
                    Text(companionManager.isClaudeCodeSignedIn
                         ? (ClickySettings.brainAuthMode == .apiKey ? "Answers are billed to your API key." : "Answers run on your plan through Claude Code.")
                         : "Click to open Setup.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func openSetupWindow() {
        SetupWindowController.show(companionManager: companionManager) {}
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            // Opens the Diagnostics window; its checks run only from the buttons inside it.
            Button(action: {
                DiagnosticsWindowController.show(companionManager: companionManager)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 11, weight: .medium))
                    Text("Diagnostics")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            // Opens the Agents window: every agent Clicky runs, with usage and history.
            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
                companionManager.showAgentsDashboard(activatesClicky: true)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                    Text("Agents…")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.leading, 10)

            Spacer()

            Button(action: {
                openSetupWindow()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                    Text("Setup…")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.leading, 10)

            Spacer()

            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

}

// MARK: - Voice Picker

/// Lets the user pick the voice that answers them (the local Qwen AI voice or
/// an installed Mac voice), with a quick preview. Its own view so it can
/// observe the speech objects directly.
private struct CompanionVoicePickerRow: View {
    @ObservedObject var speechOutput: CompanionSpeechOutput
    @ObservedObject var systemVoiceClient: SystemVoiceTTSClient
    @ObservedObject var qwenServerSupervisor: QwenServerSupervisor
    /// Opens the Voices window (the voice gallery).
    let openVoiceGallery: () -> Void
    @AppStorage(ClickySettings.Keys.qwenSpeaker) private var qwenSpeaker = QwenTuning.defaultSpeaker
    @AppStorage(ClickySettings.Keys.qwenInstruct) private var qwenInstruct = QwenTuning.instructPresets[0].instruct

    /// Opens System Settings > Accessibility > Spoken Content, where the
    /// System Voice menu has "Manage Voices…" to download Premium voices.
    private static let spokenContentSettingsURLString = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Voice")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                voiceMenu

                // The gallery: every cloned and Mac voice with Play and "Use this voice".
                Button(action: openVoiceGallery) {
                    Text("Voices…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Voice gallery")

                Button(action: {
                    speechOutput.previewVoice()
                }) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .frame(width: 24, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Preview")
            }

            if speechOutput.usesQwenLocalVoice {
                qwenVoiceSettings
            }

            if !speechOutput.usesQwenLocalVoice && !SystemVoiceTTSClient.hasHighQualityVoiceInstalled {
                Button(action: {
                    if let spokenContentSettingsURL = URL(string: Self.spokenContentSettingsURLString) {
                        NSWorkspace.shared.open(spokenContentSettingsURL)
                    }
                }) {
                    Text("Sounds robotic? Download a Premium voice (System Voice → Manage Voices…)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.accentText)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 4)
    }

    /// Qwen speaker, style instruction, a test button (speaks only when
    /// clicked) and the server supervisor's status line.
    private var qwenVoiceSettings: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Speaker")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
                Menu {
                    ForEach(QwenTuning.speakers, id: \.self) { speaker in
                        Button(Self.speakerMenuTitle(speaker)) {
                            qwenSpeaker = speaker
                            qwenServerSupervisor.refreshReadyStatus()
                        }
                    }
                } label: {
                    Text(Self.speakerMenuTitle(qwenSpeaker))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
            }

            HStack(spacing: 6) {
                TextField("Style instruction", text: $qwenInstruct)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                Menu {
                    ForEach(QwenTuning.instructPresets, id: \.name) { preset in
                        Button(preset.name) { qwenInstruct = preset.instruct }
                    }
                } label: {
                    Text("Presets")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()
            }

            HStack(spacing: 8) {
                Text(qwenServerSupervisor.status)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: {
                    speechOutput.previewVoice()
                }) {
                    Text("Test voice")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if qwenServerSupervisor.client.referenceClipBase64 == nil {
                Text("No reference voice clip at \(ClickySettings.qwenReferenceClipPath), so the voice may change between answers.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }

    private static func speakerMenuTitle(_ speaker: String) -> String {
        let displayName = speaker.replacingOccurrences(of: "_", with: " ")
        return QwenTuning.englishNativeSpeakers.contains(speaker) ? "\(displayName) · English native" : displayName
    }

    private var voiceMenu: some View {
        Menu {
            if QwenLocalTTSClient.isAvailable {
                Button("Qwen · local AI voice (best)") {
                    speechOutput.selectQwenLocalVoice()
                    speechOutput.previewVoice()
                }
                Divider()
            }
            Button("Automatic Mac voice") {
                speechOutput.selectSystemVoice(identifier: nil)
                speechOutput.previewVoice()
            }
            ForEach(SystemVoiceTTSClient.selectableEnglishVoices(), id: \.identifier) { selectableVoice in
                Button(Self.menuTitle(for: selectableVoice)) {
                    speechOutput.selectSystemVoice(identifier: selectableVoice.identifier)
                    speechOutput.previewVoice()
                }
            }
        } label: {
            Text(currentVoiceLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .pointerCursor()
    }

    private var currentVoiceLabel: String {
        if speechOutput.usesQwenLocalVoice { return "Qwen · local AI" }
        guard let voiceInUse = systemVoiceClient.voiceInUse else { return "System default" }
        let automaticSuffix = systemVoiceClient.selectedVoiceIdentifier == nil ? " (auto)" : ""
        return Self.menuTitle(for: voiceInUse) + automaticSuffix
    }

    private static func menuTitle(for voice: AVSpeechSynthesisVoice) -> String {
        let qualityLabel: String
        switch voice.quality {
        case .premium: qualityLabel = " · Premium"
        case .enhanced: qualityLabel = " · Enhanced"
        default: qualityLabel = ""
        }
        return "\(voice.name) (\(voice.language))\(qualityLabel)"
    }
}
