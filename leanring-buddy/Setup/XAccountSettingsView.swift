//
//  XAccountSettingsView.swift
//  leanring-buddy
//
//  Settings › Voice › Vello's X account: the bot's handle, its browser, where its voice goes, the monitor switch, a setup
//  checklist that updates by itself, and "Join a Space as Vello" (also on Home). Vello never touches the X page: it opens
//  a link in the bot's browser, and a person taps Join and Request to speak there.
//

import AVFoundation
import ClickyCore
import Combine
import CoreGraphics
import SwiftUI

struct XAccountSettingsSection: View {
    @AppStorage(XAccountSettings.handleKey) private var handle = ""
    @AppStorage(XAccountSettings.browserKey) private var browserBundleID = ""
    @AppStorage(XAccountSettings.outputDeviceKey) private var outputDeviceUID = ""
    @AppStorage(XAccountSettings.monitorKey) private var monitors = false
    @State private var browsers: [BotBrowserApp] = []
    @State private var outputs: [AudioDevices.Device] = []
    @State private var audioCaptureAllowed: Bool?
    @State private var screenRecordingAllowed = false
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TheoSection(title: "Vello's X account",
                    hint: "Vello joins X Spaces as itself on its own account, in a second browser signed in to that account. It hears only that browser and speaks into it through BlackHole, and it never clicks or types on X: you tap Join and Request to speak. Turn on X's Automated label for the account (Settings › Your account › Account information › Automation).") {
            SettingRow(title: "The bot's handle", detail: "Vello says this is its account when asked.") {
                TextField("@vello_ai", text: $handle).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onChange(of: handle) { _, _ in AccurateTextReading.warmUp() }
            }
            RowDivider()
            SettingRow(title: "The bot's browser", detail: "A browser that isn't your everyday Chrome, signed in to the bot's X account.") {
                Picker("The bot's browser", selection: browserSelection) {
                    if browsers.isEmpty { Text("None installed").tag("") }
                    ForEach(browsers, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                .labelsHidden().frame(width: 220).disabled(browsers.isEmpty)
            }
            RowDivider()
            SettingRow(title: "Vello's voice goes to", detail: "Set the bot's browser's microphone to this device once (in X's or the browser's mic settings).") {
                Picker("Vello's voice goes to", selection: outputSelection) {
                    if outputs.isEmpty { Text("No output devices").tag("") }
                    ForEach(outputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().frame(width: 220)
            }
            RowDivider()
            SettingRow(title: "Also play Vello on this Mac", detail: "Hear what Vello says in the Space through this Mac's speakers.") {
                Toggle("Also play Vello on this Mac", isOn: $monitors).toggleStyle(.switch).labelsHidden()
            }
            RowDivider()
            checklist
            RowDivider()
            SettingRow(title: "Open the bot's browser") {
                Button("Open the bot's browser") { XAccountSettings.openBotBrowser() }
                    .buttonStyle(.theo(.secondary, .small)).disabled(XAccountSettings.browser == nil)
                    .pointerCursor()
            }
            RowDivider()
            JoinSpaceForm().padding(.horizontal, 14).padding(.vertical, 10)
        }
        .onAppear(perform: refresh)
        .onReceive(ticker) { _ in refresh() }
    }

    /// The picked browser, or the one Vello would use when none was picked.
    private var browserSelection: Binding<String> {
        Binding(get: { browsers.contains { $0.bundleID == browserBundleID } ? browserBundleID : (XAccountSettings.browser?.bundleID ?? "") },
                set: { browserBundleID = $0 })
    }

    private var outputSelection: Binding<String> {
        Binding(get: { outputs.contains { $0.uid == outputDeviceUID } ? outputDeviceUID : (XAccountSettings.outputDeviceUID ?? "") },
                set: { outputDeviceUID = $0 })
    }

    private var checklist: some View {
        let browser = XAccountSettings.browser
        let items = XAccountChecklist.items(handle: handle, blackHoleFound: outputs.contains { $0.name.lowercased().contains("blackhole") },
                                            browserName: browser?.name, browserInstalled: browser != nil,
                                            audioCaptureAllowed: audioCaptureAllowed, screenRecordingAllowed: screenRecordingAllowed)
        return VStack(alignment: .leading, spacing: 7) {
            Text("Setup").font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary)
            ForEach(items, id: \.title) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                        .foregroundColor(item.isDone ? DS.Colors.accent : DS.Colors.textDisabled)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(TheoType.body).foregroundColor(DS.Colors.textPrimary)
                        if !item.isDone {
                            Text(item.fix).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if item.title.hasPrefix("Hearing"), audioCaptureAllowed != true {
                        Button("Check hearing") { AudioCapturePermission.request { _ in refresh() } }
                            .buttonStyle(.theo(.secondary, .small)).pointerCursor()
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func refresh() {
        browsers = XAccountSettings.installedBrowsers()
        outputs = AudioDevices.outputs()
        audioCaptureAllowed = AudioCapturePermission.isGranted
        screenRecordingAllowed = CGPreflightScreenCaptureAccess()
    }
}

/// "Join a Space as Vello": an optional Space link, opened in the bot's browser, and the call on Vello's own account.
struct JoinSpaceForm: View {
    @State private var link = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Space link (optional), x.com/i/spaces/…", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit(join)
                Button(action: join) { Label("Join a Space as Vello", systemImage: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.theoPrimary).pointerCursor()
            }
            Text(problem ?? CallOwnAccount.joinNote).font(TheoType.caption)
                .foregroundColor(problem == nil ? DS.Colors.textTertiary : DS.Colors.warning)
        }
    }

    private func join() {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = XAccountSettings.spaceLink(from: trimmed)
        if !trimmed.isEmpty, url == nil {
            problem = "That isn't an X link. Paste the Space's link, or leave it empty."
            return
        }
        problem = TheoCallController.joinSpaceAsVello(link: url)
    }
}

/// Home's "Join a Space" button: the same form in a popover.
struct JoinSpaceButton: View {
    @State private var showsForm = false

    var body: some View {
        Button { showsForm = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 12, weight: .semibold))
                Text("Join a Space").font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textPrimary).padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(DS.Colors.hover))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).help("Join an X Space as Vello, on its own X account").pointerCursor()
        .popover(isPresented: $showsForm, arrowEdge: .bottom) {
            JoinSpaceForm().padding(14).frame(width: 520)
        }
    }
}
