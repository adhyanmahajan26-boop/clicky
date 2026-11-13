//
//  UpdateButton.swift
//  leanring-buddy
//
//  The Update button that's always in reach: at the bottom of the main window's sidebar and in the menu-bar
//  panel. One click checks; when a newer build is out it says so and the same click installs it (Theo quits,
//  swaps itself in place and reopens, keeping settings and permissions). Settings › Updates has the details.
//

import ClickyCore
import SwiftUI

struct UpdateButton: View {
    /// Where it sits: the sidebar's hairline row or the menu-bar panel's footer.
    enum Placement { case sidebar, panel }

    @ObservedObject var updateController: UpdateController
    let placement: Placement

    var body: some View {
        Button(action: tapped) {
            switch placement {
            case .sidebar: sidebarLabel
            case .panel: panelLabel
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isBusy)
        .help(helpText)
    }

    private var sidebarLabel: some View {
        HStack(spacing: 10) {
            HairlineIcon(name: "updates", size: 20, color: hasUpdate ? DS.Colors.accent : DS.Colors.textSecondary, live: isBusy)
            Text(hasUpdate ? "Update Theo" : "Updates").font(.system(size: 13, weight: hasUpdate ? .semibold : .regular))
                .foregroundColor(DS.Colors.textPrimary).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
            Text(shortStatus).font(.system(size: 11.5, weight: hasUpdate ? .semibold : .regular))
                .foregroundColor(hasUpdate ? DS.Colors.accent : DS.Colors.textTertiary).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hasUpdate ? DS.Colors.accent.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }

    private var panelLabel: some View {
        // Short, so it fits the footer beside the other links; the tooltip says the rest.
        Text(hasUpdate ? "Update now" : isBusy ? shortStatus : "Update")
            .font(.system(size: 11.5, weight: hasUpdate ? .semibold : .regular))
            .foregroundColor(hasUpdate ? DS.Colors.accent : DS.Colors.textTertiary)
    }

    private var hasUpdate: Bool { updateController.availableRelease != nil }

    private var isBusy: Bool {
        switch updateController.state {
        case .checking, .installing: return true
        default: return false
        }
    }

    /// The few words on the right of the sidebar row.
    private var shortStatus: String {
        switch updateController.state {
        case .idle: return "Check"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let release): return "Build \(release.build)"
        case .installing: return "Installing…"
        case .failed: return "Try again"
        }
    }

    private var helpText: String {
        switch updateController.state {
        case .idle: return "Check for a newer build of Theo (\(updateController.currentVersionLabel))"
        case .checking: return "Checking for updates…"
        case .upToDate: return "You have the newest build (\(updateController.currentVersionLabel)). Click to check again."
        case .available: return "A newer build is ready. Theo quits, updates itself and reopens, keeping your settings and permissions."
        case .installing(let message): return message
        case .failed(let message): return message
        }
    }

    private func tapped() {
        if updateController.availableRelease != nil {
            // The test profile never replaces the installed app: it records what the button would do.
            if TheoProfile.isTest { TheoOpen.record("update install") } else { updateController.installAvailableUpdate() }
        } else {
            Task { await updateController.check() }
        }
    }
}

/// The menu-bar panel's "Update now" banner: only there while a newer build is waiting.
struct UpdateAvailableBanner: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        if let release = updateController.availableRelease {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 18)).foregroundColor(DS.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Theo build \(release.build) is ready").font(.system(size: 12.5, weight: .semibold)).foregroundColor(DS.Colors.textPrimary)
                    Text("Keeps your settings and permissions.").font(.system(size: 11)).foregroundColor(DS.Colors.textSecondary)
                }
                Spacer(minLength: 4)
                UpdateButton(updateController: updateController, placement: .panel)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Colors.surface))
        }
    }
}
