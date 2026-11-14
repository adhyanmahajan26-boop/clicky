//
//  DevicesSettings.swift
//  leanring-buddy
//
//  Settings › Devices: which Mac does what. Each Mac keeps its own choices, so "This Mac" means the Mac you're on.
//

import ClickyCore
import Combine
import IOKit
import IOKit.ps
import SwiftUI

enum DeviceRoles {
    static func key(_ feature: DeviceFeature) -> String { "v3.devices.\(feature.rawValue)" }
    private static let otherMacKey = "v5.devices.otherMac"

    /// This Mac, as the routing rules know it. Its Routines choice goes to the other Mac too, so both agree on which one fires them.
    static var thisMac: LinkedMac {
        LinkedMac(id: thisMacID, name: TheoLink.localName, isDesktop: thisMacIsDesktop, routinesChoice: choice(.routines))
    }

    /// The Mac's hardware UUID: it stays when the Mac is renamed, and isn't copied to a new Mac with the settings, as a saved id
    /// would be. Two test profiles on one Mac stand in for two Macs, so a test profile goes by its link name instead.
    static let thisMacID: String = {
        if TheoProfile.isTest { return "test:\(TheoLink.localName)" }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(entry) }
        let uuid = IORegistryEntryCreateCFProperty(entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        return uuid ?? "name:\(TheoLink.localName)"
    }()

    /// No internal battery: a Mac Studio, Mac mini, iMac or Mac Pro, the kind that's left on. A test profile can say
    /// (`test.devices.isDesktop`), and one standing in for another model (`test.studio.model`) is a desktop if that model is a Studio.
    static let thisMacIsDesktop: Bool = {
        if TheoProfile.isTest, let said = UserDefaults.standard.object(forKey: "test.devices.isDesktop") as? Bool { return said }
        if TheoProfile.isTest, let model = UserDefaults.standard.string(forKey: "test.studio.model") { return StudioGate.isMacStudio(model: model) }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        let hasInternalBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return !hasInternalBattery
    }()

    /// What builds that knew only a Mac Studio and a MacBook Air called this Mac, for reading the choices they saved. A test profile
    /// standing in for another model (`test.studio.model`) is that model.
    static let thisMacWasMacStudio: Bool = {
        if TheoProfile.isTest, let model = UserDefaults.standard.string(forKey: "test.studio.model") { return StudioGate.isMacStudio(model: model) }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(entry) }
        let productName = (IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
        return StudioGate.isMacStudio(model: StudioGate.currentModel, productName: productName)
    }()

    /// The other Mac as last heard from over Theo Link. Kept on disk, so both Macs still agree on who does what while it's away.
    static var otherMac: LinkedMac? {
        UserDefaults.standard.data(forKey: otherMacKey).flatMap { try? JSONDecoder().decode(LinkedMac.self, from: $0) }
    }

    /// Called with each description the other Mac sends of itself.
    static func rememberOtherMac(_ snapshot: DeviceSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot.linkedMac) else { return }
        UserDefaults.standard.set(data, forKey: otherMacKey)
    }

    /// This Mac and the linked one, as things stand.
    @MainActor static var pair: MacPair {
        let link = TheoLink.shared
        return MacPair(thisMac: thisMac, otherMac: link.isPaired ? otherMac : nil, paired: link.isPaired, otherMacOnline: link.isConnected)
    }

    static func choice(_ feature: DeviceFeature) -> DeviceChoice {
        UserDefaults.standard.string(forKey: key(feature)).flatMap { DeviceChoice.fromSaved($0, thisMacWasMacStudio: thisMacWasMacStudio) } ?? feature.defaultChoice
    }

    static func migrateOnce() {
        splitBotsAndRoutinesOnce()
        saveThisOrOtherMacOnce()
    }

    /// Once: "Bots" used to mean bots, coding and routines together. A setup that never picked is on the new default by itself, since only a
    /// choice someone made is saved. One that did pick keeps it for bots, and its routines stay on that Mac too.
    private static func splitBotsAndRoutinesOnce() {
        let flag = "v3.devices.splitBotsAndRoutines"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        guard let stored = defaults.string(forKey: key(.bots)), stored != DeviceChoice.any.rawValue, defaults.string(forKey: key(.routines)) == nil else { return }
        defaults.set(stored, forKey: key(.routines))
    }

    /// Once: choices saved as "Mac Studio" or "MacBook Air" become "This Mac" or "The other Mac", by what this Mac was taken for then,
    /// so each Mac does what it did before. Unsaved ones need nothing: the old default, the Mac Studio, and the new one, the always-on
    /// Mac, are the same Mac on a Studio and a laptop.
    private static func saveThisOrOtherMacOnce() {
        let flag = "v5.devices.thisOrOtherMac"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        for feature in DeviceFeature.allCases {
            guard let stored = defaults.string(forKey: key(feature)), let choice = DeviceChoice.fromSaved(stored, thisMacWasMacStudio: thisMacWasMacStudio),
                  choice.rawValue != stored else { continue }
            defaults.set(choice.rawValue, forKey: key(feature))
        }
    }

    @MainActor static func route(_ feature: DeviceFeature) -> DeviceRoute {
        // A product that's off (Settings › Products) doesn't run here, whichever Mac it's set to.
        if let product = TheoProduct.owning(feature), !TheoProducts.isOn(product) { return .notHere }
        return DeviceRouting.route(feature, choice: choice(feature), pair: pair)
    }

    @MainActor static func runsHere(_ feature: DeviceFeature) -> Bool { route(feature) == .runHere }
}

struct DevicesSettingsContent: View {
    @ObservedObject private var link = TheoLink.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            TheoSection(title: "Your Macs", hint: nil) {
                macRow(name: TheoLink.shortName(TheoLink.localName), isDesktop: DeviceRoles.thisMacIsDesktop, firesRoutines: link.isPaired && DeviceRoles.runsHere(.routines),
                       tag: "This Mac", isOnline: true, build: currentBuild)
                RowDivider()
                if let other = link.peerName ?? link.knownPeerName {
                    macRow(name: TheoLink.shortName(other), isDesktop: DeviceRoles.otherMac?.isDesktop, firesRoutines: !DeviceRoles.runsHere(.routines),
                           tag: nil, isOnline: link.isConnected, build: link.peerBuild)
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
            LocalAPISection()
        }
    }

    private var currentBuild: Int? { Bundle.main.infoDictionary?["CFBundleVersion"].flatMap { ($0 as? String).flatMap(Int.init) } }

    /// "Desktop · fires routines": what kind of Mac it is, when known, and whether it's the one routines fire on.
    private func macRow(name: String, isDesktop: Bool?, firesRoutines: Bool, tag: String?, isOnline: Bool, build: Int?) -> some View {
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
                let kind = isDesktop.map { $0 ? "Desktop" : "Laptop" }
                let caption = [kind, firesRoutines ? "fires routines" : nil].compactMap { $0 }.joined(separator: " · ")
                if !caption.isEmpty { Text(caption).font(TheoType.caption).foregroundColor(DS.Colors.textTertiary) }
            }
            Spacer()
            if let build { Text("build \(String(build))").font(.system(size: 11, design: .monospaced)).foregroundColor(DS.Colors.textTertiary) }
            StatusPill(text: isOnline ? "Online" : "Offline", tone: isOnline ? .good : .neutral)
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
            if feature == .studioScreens, !StudioController.canMakeHiddenScreens {
                Text("Not on this Mac").font(TheoType.caption).foregroundColor(DS.Colors.textTertiary)
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
        // The other Mac weighs this Mac's Routines choice too, so it hears of a change soon.
        if feature == .routines { TheoLink.shared.syncSoon() }
    }
}

/// Theo's local API (`TheoGateway`): off by default. Scripts on this Mac message a bot or fire a routine with the token, which stays in the Keychain.
private struct LocalAPISection: View {
    @State private var enabled = TheoGateway.isEnabled
    @State private var copied = false

    var body: some View {
        TheoSection(title: "Local API", hint: "Lets scripts, cron jobs and webhook relays on this Mac message a bot or run a routine, over http://127.0.0.1:\(TheoGateway.port). Nothing off this Mac can reach it. What comes in this way shows in the chat as from that program and is never taken as your own words: it can't start coding runs or routines.") {
            SettingRow(title: "Turn on the local API", detail: enabled ? "Listening on 127.0.0.1:\(TheoGateway.port)." : "Off.") {
                Toggle("", isOn: Binding(get: { enabled }, set: { enabled = $0; TheoGateway.shared.setEnabled($0) })).labelsHidden().toggleStyle(.switch)
            }
            if enabled {
                RowDivider()
                SettingRow(title: "Token", detail: "Send it as Authorization: Bearer <token>. A new token stops the old one at once.") {
                    HStack(spacing: 8) {
                        Button(copied ? "Copied" : "Copy token") {
                            if let token = TheoGatewayToken.read() {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(token, forType: .string)
                                copied = true
                            }
                        }.buttonStyle(.theoSecondary)
                        Button("New token") { TheoGatewayToken.renew(); copied = false }.buttonStyle(.theoSecondary)
                    }
                }
            }
        }
    }
}
