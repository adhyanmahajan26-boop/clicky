//
//  CodeModeSettingsRow.swift
//  leanring-buddy
//
//  The "Code mode" switch in the menu-bar panel (v2.code.enabled, default
//  off) with the preflight status line under it, and a small "Clean up
//  worktrees" action once it's on.
//

import ClickyCore
import SwiftUI

struct CodeModeSettingsRow: View {
    @ObservedObject var codeModeController: CodeModeController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Code mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { codeModeController.isEnabled },
                    set: { codeModeController.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
            }

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
                .padding(.leading, 24)

            if codeModeController.isEnabled && !codeModeController.isBusy {
                Button("Clean up worktrees") { codeModeController.cleanUpWorktrees() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if codeModeController.isBusy { return codeModeController.phaseDescription }
        return codeModeController.preflightStatusLine
    }
}
