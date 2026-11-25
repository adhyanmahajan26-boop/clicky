//
//  HandSignSettings.swift
//  leanring-buddy
//
//  Settings › Accessibility (Addy's "disability mode": for people who sign, or who can't use their voice or hands
//  the usual way): the Accessibility mode switch (`v5.handSigns.enabled`, as before it moved here from Pointer
//  Assistant's page), what signs do, the camera picture, Spell to text
//  (which alphabet, where the text goes, and teaching it new signs), Sign to text (which sign language,
//  where the line goes, when it sends by itself, and what it can read), and each sign's phrase (what
//  "Speak for me" says), which the owner can rewrite.
//

import ClickyCore
import SwiftUI

/// The Accessibility page. Pointer Assistant's page keeps one line pointing here.
struct AccessibilitySettingsContent: View {
    private var manager: CompanionManager? { CompanionManager.current }

    var body: some View {
        if let manager {
            HandSignSettingsSection(controller: manager.handSignController)
        } else {
            Text("Accessibility settings appear once Vello has started.").font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
        }
    }
}

struct HandSignSettingsSection: View {
    @ObservedObject var controller: HandSignController
    @State private var isOn = HandSignController.isEnabled
    @State private var phrases = HandSignController.phrases
    @State private var signToTeach = ""

    var body: some View {
        TheoSection(title: "Hand signs", hint: "On this Mac only: the camera picture is read by Apple's hand tracking and never saved or sent. The camera stops while the screen is locked.") {
            SettingRow(title: "Accessibility mode", detail: controller.problem ?? "Reads hand signs on the camera. Opens the camera and a small panel; hold a sign still for about a second.") {
                Toggle("Accessibility mode", isOn: Binding(get: { isOn }, set: { value in
                    isOn = value
                    controller.setEnabled(value)
                })).toggleStyle(.switch).labelsHidden()
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "What signs do", detail: controller.mode.detail) {
                // Four modes with long names: a menu rather than segments.
                Picker("What signs do", selection: $controller.mode) {
                    ForEach(HandSignMode.allCases, id: \.self) { mode in Text(Self.experimentalName(mode.displayName, mode.isExperimental)).tag(mode) }
                }
                .labelsHidden().frame(width: 260)
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "Show the camera picture", detail: "Off: the panel only shows the sign it sees.") {
                Toggle("Show the camera picture", isOn: $controller.showsCameraPicture).toggleStyle(.switch).labelsHidden()
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "Spell to text: alphabet", detail: controller.alphabet.detail) {
                Picker("Alphabet", selection: $controller.alphabet) {
                    ForEach(FingerspellingAlphabet.allCases, id: \.self) { alphabet in Text(Self.experimentalName(alphabet.displayName, alphabet.isExperimental)).tag(alphabet) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "Spell to text: send to", detail: controller.destination.detail) {
                Picker("Send to", selection: $controller.destination) {
                    ForEach(SpelledTextDestination.allCases, id: \.self) { destination in Text(Self.destinationName(destination)).tag(destination) }
                }
                .labelsHidden().frame(width: 220)
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "Sign to text (Experimental): what it reads", detail: Self.signsHonestLine(for: controller.signLanguage)) {
                EmptyView()
            }
            RowDivider()
            SettingRow(title: "Sign to text: sign language", detail: signModelsWords) {
                Picker("Sign language", selection: $controller.signLanguage) {
                    ForEach(SignLanguage.allCases, id: \.self) { language in Text(language.displayName).tag(language) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "Sign to text: send to", detail: controller.signsDestination.detail) {
                Picker("Send to", selection: $controller.signsDestination) {
                    ForEach(SpelledTextDestination.allCases, id: \.self) { destination in Text(Self.destinationName(destination)).tag(destination) }
                }
                .labelsHidden().frame(width: 220)
                .pointerCursor()
            }
            RowDivider()
            SettingRow(title: "Sign to text: send by itself",
                       detail: "Once your hands have rested this long with words waiting. Off: only Send sends.") {
                Stepper(value: $controller.signsAutoSendSeconds, in: 0...10, step: 0.5) {
                    Text(controller.signsAutoSendSeconds <= 0 ? "Off" : String(format: "After %.1f s", controller.signsAutoSendSeconds))
                        .font(TheoType.body).foregroundColor(DS.Colors.textSecondary)
                        .frame(minWidth: 80, alignment: .trailing)
                }
                .pointerCursor()
                .help("How long your hands rest before the line sends by itself")
            }
            RowDivider()
            teachRow
            ForEach(controller.taughtSigns.signs, id: \.label) { taughtSign in
                RowDivider()
                taughtSignRow(taughtSign)
            }
            ForEach(HandSign.allCases, id: \.self) { sign in
                RowDivider()
                signRow(sign)
            }
        }
    }

    /// What Sign to text can and can't do, said plainly.
    /// "Pointer Assistant (off)" while that product is off: Spell to text and Sign to text can't send there then.
    static func destinationName(_ destination: SpelledTextDestination) -> String {
        destination == .pointerAssistant && !TheoProducts.isOn(.clicky) ? "\(destination.displayName) (off)" : destination.displayName
    }

    /// What Sign to text can read in each language, measured on signers the models never saw (docs/SIGN-LANGUAGE.md).
    static func signsHonestLine(for language: SignLanguage) -> String {
        switch language {
        case .isl:
            return "Reads 261 ISL signs and short runs of them. So far it has only been shown to work for the signers it learned from, so expect it to show ? often."
        case .asl:
            return "Reads 562 ASL signs, one at a time, and finger-spelling. On people it never saw it answers a little under half of signs and is right on about 9 in 10 of those, and gets about 9 in 10 finger-spelled letters right. Expect it to show ? often."
        }
    }

    /// "Sign to text (Experimental)": the word beside the names of what has only been shown on a few signers.
    static func experimentalName(_ name: String, _ isExperimental: Bool) -> String {
        isExperimental ? "\(name) (Experimental)" : name
    }

    /// Which models Sign to text found for the chosen language, or what's missing.
    private var signModelsWords: String {
        // Said plainly, before anything loads: a language this build has no models for.
        if !SignModelFolders.hasModels(for: controller.signLanguage) { return controller.signLanguage.notInThisBuildLine }
        if let modelsProblem = controller.signModelsProblem { return modelsProblem }
        guard let signModelsLoad = controller.signModelsLoad, signModelsLoad.language == controller.signLanguage else {
            return "Its models load when Sign to text is turned on."
        }
        let modelWords = [signModelsLoad.wordModelSummary, signModelsLoad.spellingModelSummary].compactMap { $0 }
        let sentenceWords = signModelsLoad.sentenceModelSummary.map { " Runs of signs without a rest are read by \($0)." } ?? ""
        return "Ready: \(modelWords.joined(separator: "; ")).\(sentenceWords)"
    }

    /// Teach a letter or word: write it, press Teach, and hold the sign to the camera for two seconds.
    private var teachRow: some View {
        SettingRow(title: "Teach a sign",
                   detail: controller.teachingLine.isEmpty
                       ? "For ISL letters, words, or a letter it misreads on your hand. One hand or two, held still."
                       : controller.teachingLine) {
            HStack(spacing: 8) {
                TextField("Letter or word", text: $signToTeach)
                    .theoField().frame(width: 140)
                    .onSubmit { controller.startTeaching(label: signToTeach) }
                Button(controller.teachingLabel == nil ? "Teach" : "Stop") {
                    if controller.teachingLabel == nil {
                        controller.startTeaching(label: signToTeach)
                    } else {
                        controller.stopTeaching()
                    }
                }
                .pointerCursor()
                .help("Hold the sign to the camera; it takes \(TaughtSignBook.examplesWhenTeaching) looks")
            }
        }
    }

    private func taughtSignRow(_ taughtSign: TaughtSign) -> some View {
        HStack(spacing: 12) {
            Text(taughtSign.label.count == 1 ? taughtSign.label.uppercased() : "★")
                .font(.system(size: 16, weight: .bold)).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(taughtSign.label).font(TheoType.body).foregroundColor(DS.Colors.textPrimary)
                Text("\(taughtSign.handCount == 2 ? "Two hands" : "One hand"), shown \(taughtSign.examples.count) times")
                    .font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer(minLength: 12)
            Button("Forget") { controller.forgetTaughtSign(label: taughtSign.label) }
                .pointerCursor()
                .help("Forget this taught sign")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
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
        case .startListening: return "Control: starts a call with Vello, talk to it"
        case .stopEverything: return "Control: stop, like Esc"
        case .answer(let yes): return yes ? "Control: yes to what it's asking" : "Control: no to what it's asking"
        case .ask: return "Control: asks what's on your screen"
        case .speak: return "Control and Speak for me: says the phrase"
        case .nothing: return "Says nothing"
        }
    }
}
