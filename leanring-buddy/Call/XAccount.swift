//
//  XAccount.swift
//  leanring-buddy
//
//  Vello's X account (Settings › Voice › Vello's X account): the bot's handle, the bot's browser (a second Chromium
//  browser signed in to the bot's account, never the owner's everyday Chrome), the virtual mic Vello's voice goes to
//  (BlackHole), and whether Vello is also played on this Mac. A Space joined this way is heard only from that browser
//  and spoken into it (ClickyCore `CallOwnAccount`).
//
//  X's automation rules ban scripting the X website: Vello only opens a link in that browser (like `open -a`), hears its
//  sound and passively looks at its window. It never clicks, types, runs script or reads the page there.
//

import AppKit
import AudioToolbox
import ClickyCore
import CoreAudio
import Foundation

enum XAccountSettings {
    static let handleKey = "v5.xAccount.handle"
    static let browserKey = "v5.xAccount.browser"
    static let outputDeviceKey = "v5.xAccount.outputDevice"
    static let monitorKey = "v5.xAccount.monitor"
    /// The bot account's display name on X ("Chotta Tirri"): its own tile in a Space shows this, so it's never taken for
    /// someone talking.
    static let displayNameKey = "v5.xAccount.displayName"

    /// "@vello_ai", or empty.
    static var handle: String { XHandle.normalized(UserDefaults.standard.string(forKey: handleKey) ?? "") }

    /// The bot's browser: the one picked, else the first one installed. Never the everyday Google Chrome.
    static var browser: BotBrowserApp? {
        if let saved = UserDefaults.standard.string(forKey: browserKey), BotBrowserChoice.isAllowed(bundleID: saved), appURL(bundleID: saved) != nil {
            return BotBrowserChoice.candidates.first { $0.bundleID == saved } ?? BotBrowserApp(bundleID: saved, name: appName(bundleID: saved))
        }
        return BotBrowserChoice.suggested(installedBundleIDs: installedBrowsers().map(\.bundleID))
    }

    /// The device Vello's voice plays to: the one picked while it's connected, else the first BlackHole.
    static var outputDeviceUID: String? {
        let outputs = AudioDevices.outputs()
        if let saved = UserDefaults.standard.string(forKey: outputDeviceKey), outputs.contains(where: { $0.uid == saved }) { return saved }
        return VirtualMicChoice.defaultDeviceUID(among: outputs.map { ($0.uid, $0.name) })
    }

    /// "Also play Vello on this Mac".
    static var monitors: Bool { UserDefaults.standard.bool(forKey: monitorKey) }

    static var blackHoleFound: Bool { AudioDevices.outputs().contains { $0.name.lowercased().contains("blackhole") } }

    /// The Chromium browsers on this Mac that can be the bot's.
    static func installedBrowsers() -> [BotBrowserApp] {
        BotBrowserChoice.candidates.filter { appURL(bundleID: $0.bundleID) != nil }
    }

    static func appURL(bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func appName(bundleID: String) -> String {
        guard let url = appURL(bundleID: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// What a Space joined now uses, read once at the start.
    static func setup() -> XAccountSetup {
        let browser = browser
        return XAccountSetup(handle: handle, displayName: UserDefaults.standard.string(forKey: displayNameKey) ?? "",
                             browser: browser, browserAppURL: browser.flatMap { appURL(bundleID: $0.bundleID) },
                             outputDeviceUID: outputDeviceUID, monitors: monitors)
    }

    /// Opens the bot's browser, with `link` (a Space) in it when there is one. Only opens it: nothing on the page is touched.
    @discardableResult
    static func openBotBrowser(link: URL? = nil) -> String? {
        guard let browser, let appURL = appURL(bundleID: browser.bundleID) else {
            return "Pick the bot's browser in Settings › Voice › Vello's X account first."
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let link {
            NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
        return nil
    }

    /// A Space link as pasted ("x.com/i/spaces/1abc…", with or without https), or nil when it isn't one.
    static func spaceLink(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              host == "x.com" || host.hasSuffix(".x.com") || host == "twitter.com" || host.hasSuffix(".twitter.com") else { return nil }
        return url
    }
}

/// What one own-account Space uses.
struct XAccountSetup {
    var handle: String
    var displayName: String = ""
    var browser: BotBrowserApp?
    var browserAppURL: URL?
    var outputDeviceUID: String?
    var monitors: Bool
}

/// The Mac's audio devices, through Core Audio.
enum AudioDevices {
    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    static func outputs() -> [Device] { all().filter { channelCount(of: $0.id, scope: kAudioObjectPropertyScopeOutput) > 0 } }
    static func inputs() -> [Device] { all().filter { channelCount(of: $0.id, scope: kAudioObjectPropertyScopeInput) > 0 } }

    static func device(uid: String) -> Device? { all().first { $0.uid == uid } }

    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let uid = string(kAudioDevicePropertyDeviceUID, of: id), let name = string(kAudioObjectPropertyName, of: id) else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    /// The system's default output device's UID, which a process tap's private device runs on.
    static var defaultOutputUID: String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr else { return nil }
        return string(kAudioDevicePropertyDeviceUID, of: id)
    }

    static func string(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channelCount(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

/// macOS's "System Audio Recording" permission, which hearing another app's sound needs. macOS has no public call for
/// whether it's granted, so this asks the privacy service the way the system's own sample apps for process taps do;
/// nil when that can't be read.
enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let framework = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// True granted, false refused, nil not asked yet or unknown.
    static var isGranted: Bool? {
        guard let framework, let symbol = dlsym(framework, "TCCAccessPreflight") else { return nil }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// Shows macOS's own question once; the answer comes on the main actor.
    static func request(_ done: @escaping @MainActor (Bool) -> Void) {
        guard let framework, let symbol = dlsym(framework, "TCCAccessRequest") else {
            DispatchQueue.main.async { MainActor.assumeIsolated { done(false) } }
            return
        }
        unsafeBitCast(symbol, to: Request.self)(service, nil) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(granted) } }
        }
    }
}
