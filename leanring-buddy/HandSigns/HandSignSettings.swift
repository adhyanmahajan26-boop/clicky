//
//  HandSignSettings.swift
//  leanring-buddy
//
//  Settings › Pointer Assistant › Hand signs: the switch, what signs do, the camera picture, and each
//  sign's phrase (what "Speak for me" says), which the owner can rewrite.
//

import ClickyCore
import SwiftUI

struct HandSignSettingsSection: View {
    @ObservedObject var controller: HandSignController
    @State private var isOn = HandSignController.isEnabled
    @State private var phrases = HandSignController.phrases

    var body: some View {
        TheoSection(title: "Hand signs", hint: "On this Mac only: the camera picture is read by Apple's hand tracking and never saved or sent. The camera stops while the screen is locked.") {
            SettingRow(title: "Read hand signs", detail: controller.problem ?? "Opens the camera and a small panel. Hold a sign still for about a second.") {
                Toggle("Read hand signs", isOn: Binding(get: { isOn }, set: { value in
                    isOn = value
                    controller.setEnabled(value)
                })).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            SettingRow(title: "What signs do", detail: controller.mode.detail) {
                Picker("What signs do", selection: $controller.mode) {
                    ForEach(HandSignMode.allCases, id: \.self) { mode in Text(mode.displayName).tag(mode) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            }
            RowDivider()
            SettingRow(title: "Show the camera picture", detail: "Off: the panel only shows the sign it sees.") {
                Toggle("Show the camera picture", isOn: $controller.showsCameraPicture).toggleStyle(.switch).labelsHidden()
            }
            ForEach(HandSign.allCases, id: \.self) { sign in
                RowDivider()
                signRow(sign)
            }
        }
    }

    private func signRow(_ sign: HandSign) -> some View {
        HStack(spacing: 12) {
            Text(sign.emoji).font(.system(size: 20)).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(sign.displayName).font(TheoType.body).foregroundColor(DS.Colors.textPrimary)
                Text(controlModeWords(for: sign)).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 12)
            TextField(sign.defaultPhrase, text: Binding(get: { phrases[sign] ?? sign.defaultPhrase }, set: { value in
                phrases[sign] = value
                HandSignController.phrases = phrases
            }))
            .theoField().frame(width: 200)
            .help("What Speak for me says for this sign. Leave it empty to say nothing.")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// What the sign does in Control, beside its phrase.
    private func controlModeWords(for sign: HandSign) -> String {
        switch HandSignActions.action(for: sign, mode: .control, phrases: phrases) {
        case .startListening: return "Control: Pointer Assistant listens, talk to it"
        case .stopEverything: return "Control: stop, like Esc"
        case .answer(let yes): return yes ? "Control: yes to what it's asking" : "Control: no to what it's asking"
        case .ask: return "Control: asks what's on your screen"
        case .speak: return "Control and Speak for me: says the phrase"
        case .nothing: return "Says nothing"
        }
    }
}
