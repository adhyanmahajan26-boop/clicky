//
//  DevicesSettings.swift
//  leanring-buddy
//
//  Settings › Devices: which Mac does what. Each Mac keeps its own choices, so "This Mac" means the Mac you're on.
//

import ClickyCore
import Combine
import SwiftUI

enum DeviceRoles {
    static func key(_ feature: DeviceFeature) -> String { "v3.devices.\(feature.rawValue)" }

    static var thisMac: DeviceKind { StudioController.isAvailable ? .macStudio : .macBookAir }

    static func choice(_ feature: DeviceFeature) -> DeviceChoice {
        UserDefaults.standard.string(forKey: key(feature)).flatMap(DeviceChoice.init(rawValue:)) ?? feature.defaultChoice
    }

    /// Once: "Bots" used to mean bots, coding and routines together. A setup that never picked is on the new default by itself, since only a
    /// choice someone made is saved. One that did pick keeps it for bots, and its routines stay on that Mac too.
    static func migrateOnce() {
        let flag = "v3.devices.splitBotsAndRoutines"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard let stored = defaults.string(forKey: key(.bots)), stored != DeviceChoice.any.rawValue, defaults.string(forKey: key(.routines)) == nil else { return }
        defaults.set(stored, forKey: key(.routines))
    }

    @MainActor static func route(_ feature: DeviceFeature) -> DeviceRoute {
        DeviceRouting.route(feature, choice: choice(feature), thisMac: thisMac, paired: TheoLink.shared.isPaired, otherMacOnline: TheoLink.shared.isConnected)
    }

    @MainActor static func runsHere(_ feature: DeviceFeature) -> Bool { route(feature) == .runHere }
}

struct DevicesSettingsContent: View {
    @ObservedObject private var link = TheoLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Your Macs", hint: nil) {
                macRow(name: TheoLink.shortName(TheoLink.localName), kind: DeviceRoles.thisMac, tag: "This Mac", isOnline: true, build: currentBuild)
                RowDivider()
                if let other = link.peerName ?? link.knownPeerName {
                    macRow(name: TheoLink.shortName(other), kind: DeviceRoles.thisMac == .macStudio ? .macBookAir : .macStudio, tag: nil, isOnline: link.isConnected, build: link.peerBuild)
                    if link.isConnected, let theirs = link.peerBuild, let mine = currentBuild, theirs < mine {
                        RowDivider()
                        SettingRow(title: "Update \(TheoLink.shortName(other))", detail: "It checks for the latest build and installs it once it's idle.") {
                            Button("Update it") { _ = link.request("updateWhenIdle", [:]) }.buttonStyle(.theoSecondary)
                        }
                    }
                } else {
                    SettingRow(title: "No other Mac linked", detail: "Link one in Your other Mac to share the work between them.") { EmptyView() }
                }
            }
            TheoSection(title: "What runs where", hint: "Theo works on the Mac you're using: a message you type here is answered here, with this Mac's folders and coding runs. Bots and chats show on both Macs. Set a row to the other Mac and what you send goes there. If that Mac is offline, the chat says so at once and offers to run it here.") {
                ForEach(Array(DeviceFeature.allCases.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { RowDivider() }
                    DeviceFeatureRow(feature: feature)
                }
            }
        }
    }

    private var currentBuild: Int? { Bundle.main.infoDictionary?["CFBundleVersion"].flatMap { ($0 as? String).flatMap(Int.init) } }

    private func macRow(name: String, kind: DeviceKind, tag: String?, isOnline: Bool, build: Int?) -> some View {
        HStack(spacing: 10) {
            HairlineIcon(name: "screen", size: 20, color: DS.Colors.textSecondary, selected: tag != nil)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(TheoType.bodyMedium).foregroundColor(DS.Colors.textPrimary).lineLimit(1)
                    if let tag {
                        Text(tag).font(.system(size: 10.5, weight: .medium)).foregroundColor(DS.Colors.accentText)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(DS.Colors.accentSoft))
                    }
                }
                Text(kind == .macStudio ? "Mac Studio" : "MacBook Air").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            if let build { Text("build \(String(build))").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textTertiary) }
            HStack(spacing: 5) {
                Circle().fill(isOnline ? Color(hex: 0x4ADE80) : DS.Colors.textDisabled).frame(width: 7, height: 7)
                Text(isOnline ? "Online" : "Offline").font(TheoType.caption).foregroundColor(DS.Colors.textSecondary)
            }
        }
        .padding(12)
    }
}

private struct DeviceFeatureRow: View {
    let feature: DeviceFeature
    @AppStorage private var stored: String

    init(feature: DeviceFeature) {
        self.feature = feature
        _stored = AppStorage(wrappedValue: feature.defaultChoice.rawValue, DeviceRoles.key(feature))
    }

    var body: some View {
        SettingRow(title: feature.title, detail: feature.detail) {
            if feature == .studioScreens, DeviceRoles.thisMac != .macStudio {
                Text("Mac Studio only").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
            } else {
                Picker(feature.title, selection: Binding(get: { stored }, set: { stored = $0; applied() })) {
                    ForEach(DeviceChoice.allCases) { Text($0 == .any ? feature.anyChoiceTitle : $0.title).tag($0.rawValue) }
                }
                .labelsHidden().frame(width: 170)
            }
        }
    }

    /// Features that follow the setting straight away.
    private func applied() {
        if feature == .studioScreens { StudioController.shared.followDeviceSetting() }
        if feature == .clicky { TheoLink.shared.objectWillChange.send() }
    }
}
