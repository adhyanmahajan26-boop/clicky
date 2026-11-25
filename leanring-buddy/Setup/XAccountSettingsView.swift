//
//  XAccountSettingsView.swift
//  leanring-buddy
//
//  The X Space bot's account, in that bot's settings: the handle, its browser, where its voice goes, the monitor switch, a
//  setup checklist that updates by itself, and "Join a Space" (also in the bot's chat header). The bot never touches the X
//  page: it opens
//  a link in the bot's browser, and a person taps Join and Request to speak there.
//

import AVFoundation
import ClickyCore
import Combine
import CoreGraphics
import SwiftUI

struct XAccountSettingsSection: View {
    @AppStorage(XAccountSettings.handleKey) private var handle = ""
    @AppStorage(XAccountSettings.displayNameKey) private var displayName = ""
    @AppStorage(XAccountSettings.bossKey) private var boss = ""
    @AppStorage(XAccountSettings.stanceKey) private var stance = SpaceStance.normal.rawValue
    @AppStorage(XAccountSettings.stanceTargetKey) private var stanceTarget = ""
    @AppStorage(XAccountSettings.toneKey) private var tone = SpaceTone.normal.rawValue
    @AppStorage(XAccountSettings.toneCustomKey) private var toneCustom = ""
    @AppStorage(XAccountSettings.browserKey) private var browserBundleID = ""
    @AppStorage(XAccountSettings.outputDeviceKey) private var outputDeviceUID = ""
    @AppStorage(XAccountSettings.monitorKey) private var monitors = false
    @State private var browsers: [BotBrowserApp] = []
    @State private var outputs: [AudioDevices.Device] = []
    @State private var audioCaptureAllowed: Bool?
    @State private var screenRecordingAllowed = false
    private let ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TheoSection(title: "Its X account",
                    hint: "This bot joins X Spaces as itself on its own account, as a listener or speaker (never as host), in a second browser signed in to that account. It hears only that browser and speaks into it through BlackHole, and it never clicks or types on X: you tap Join and Request to speak. Turn on X's Automated label for the account (Settings › Your account › Account information › Automation).") {
            SettingRow(title: "The account's handle", detail: "The bot says this is its account when asked.") {
                TextField("@vello_ai", text: $handle).textFieldStyle(.roundedBorder).frame(width: 180)
                    .onChange(of: handle) { _, _ in AccurateTextReading.warmUp() }
            }
            RowDivider()
            SettingRow(title: "Its display name on X", detail: "Optional. A Space shows this under the bot's own picture, so the bot never takes itself for someone talking.") {
                TextField("Vello (AI)", text: $displayName).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            RowDivider()
            SettingRow(title: "Your name in Spaces", detail: "Optional: your display name or handle on X. When the Space's screen clearly shows you talking, the bot does what you ask about the conversation, and never says so there. Anyone can copy a display name, so this only steers the talk, never anything on your Mac.") {
                TextField("your_handle", text: $boss).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            RowDivider()
            SettingRow(title: "Stance", detail: "Debate takes the other side with arguments, Arguing pushes back harder, Agreeing backs people up; always against ideas, never people. Name one speaker, or leave it empty for everyone.") {
                HStack(spacing: 6) {
                    Picker("Stance", selection: $stance) {
                        ForEach(SpaceStance.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 110)
                    TextField("everyone", text: $stanceTarget).textFieldStyle(.roundedBorder).frame(width: 110)
                }
            }
            RowDivider()
            SettingRow(title: "Tone", detail: "Witty/funny, Serious, Chill, or Custom in your own words. Your boss name in a Space can switch it too.") {
                HStack(spacing: 6) {
                    Picker("Tone", selection: $tone) {
                        ForEach(SpaceTone.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 120)
                    if tone == SpaceTone.custom.rawValue {
                        TextField("e.g. like a cricket commentator", text: $toneCustom).textFieldStyle(.roundedBorder).frame(width: 200)
                    }
                }
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
            SettingRow(title: "Its voice goes to", detail: "Set the bot's browser's microphone to this device once (in the browser's mic settings).") {
                Picker("Its voice goes to", selection: outputSelection) {
                    if outputs.isEmpty { Text("No output devices").tag("") }
                    ForEach(outputs, id: \.uid) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().frame(width: 220)
            }
            RowDivider()
            SettingRow(title: "Also play it on this Mac", detail: "Hear what the bot says in the Space through this Mac's speakers.") {
                Toggle("Also play it on this Mac", isOn: $monitors).toggleStyle(.switch).labelsHidden()
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

    /// The picked browser, or the one the bot would use when none was picked.
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

/// "Join a Space": an optional Space link, opened in the bot's browser, and the X Space bot's call on its own account.
struct JoinSpaceForm: View {
    @State private var link = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Space link (optional), x.com/i/spaces/…", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit(join)
                Button(action: join) { Label("Join a Space", systemImage: "dot.radiowaves.left.and.right") }
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
        problem = TheoCallController.joinSpace(link: url)
    }
}

/// The X Space bot's "Join a Space" button: the same form in a popover.
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
        .buttonStyle(.plain).help("Join an X Space with the X Space bot, on its own X account").pointerCursor()
        .popover(isPresented: $showsForm, arrowEdge: .bottom) {
            JoinSpaceForm().padding(14).frame(width: 520)
        }
    }
}

/// Settings › Voice: X Spaces have a bot of their own now. This makes it if needed and opens it.
struct XSpaceBotLinkSection: View {
    @ObservedObject private var store = BotsStore.shared

    var body: some View {
        TheoSection(title: "X Spaces", hint: "Joining X Spaces on its own X account is a bot of its own, apart from Vello: its account, browser and voice are in its settings, and Join a Space is in its chat.") {
            SettingRow(title: store.xSpaceBot?.name ?? "X Space bot", detail: store.xSpaceBot == nil ? "Not made yet." : "Joins Spaces as a listener or speaker, never as host.") {
                Button(store.xSpaceBot == nil ? "Make the X Space bot" : "Open its chat") {
                    let bot = store.ensureXSpaceBot()
                    BotsSelection.shared.pane = .bot(bot.id)
                    if let manager = CompanionManager.current { TheoHomeWindowController.show(companionManager: manager) }
                }
                .buttonStyle(.theo(.secondary, .small)).pointerCursor()
            }
        }
    }
}
