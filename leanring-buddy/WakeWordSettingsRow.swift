//
//  WakeWordSettingsRow.swift
//  leanring-buddy
//
//  P7: the wake word's row in the menu-bar panel: an on/off switch
//  (v2.wake.enabled) and one line saying what it's doing, or why it's off
//  or paused (no on-device recognizer, a call using the mic, …).
//

import ClickyCore
import SwiftUI

struct WakeWordSettingsRow: View {
    @ObservedObject var wakeWordController: WakeWordController

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: wakeWordController.state.wantsMicrophone ? "ear.fill" : "ear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 16)

                    Text("Wake word")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { wakeWordController.isEnabled },
                    set: { wakeWordController.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .pointerCursor()
            }

            Text(statusText)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
                .padding(.leading, 24)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        switch wakeWordController.state {
        case .armed: return "Say “hey Theo” or “hey Clicky”. Heard on this Mac only."
        case .off(.disabledInSettings): return "Off. Turn on to start a question with “hey Theo”."
        default: return wakeWordController.state.displayText
        }
    }
}
