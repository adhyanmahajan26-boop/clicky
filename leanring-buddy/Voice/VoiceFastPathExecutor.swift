//
//  VoiceFastPathExecutor.swift
//  leanring-buddy
//
//  P8 local fast path, the system side. Two halves, like ActionExecutor, so
//  the tier is always decided between them:
//   - readFacts: read-only. The frontmost app and window (and its focused
//     field for copy / paste / select all / read aloud), whether its window
//     shows unsaved changes, and whether Netflix / Safari is likely what's
//     playing (Safari in front, or a window title that says Netflix).
//   - perform: does one command whose tier allowed it. CoreAudio for the
//     default output's volume and mute; DisplayServices for a built-in
//     display's brightness (skipped on external displays); tagged
//     system-defined media key events; AX position / size for windows;
//     NSWorkspace for apps, files, Mission Control and the desktop; tagged
//     key events (SyntheticEvents) for tabs, history, copy / paste;
//     tagged scroll events; AX selected text for "read this aloud"; the
//     [SNAP] capture for screenshots; ⌃⌘Q for lock (after a yes).
//

import AppKit
import ApplicationServices
import AudioToolbox
import Carbon.HIToolbox
import ClickyCore
import CoreAudio

enum VoiceFastPathOutcome {
    case done(detail: String, acknowledgement: String)
    /// Nothing matched on this Mac (no app called that, no such folder): the turn goes to Claude.
    case notHandled(reason: String)
    case failed(reason: String, spokenLine: String)
}

@MainActor
final class VoiceFastPathExecutor {
    private unowned let companionManager: CompanionManager

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    // MARK: - Facts (read only)

    func readFacts(for command: VoiceFastPathCommand) -> VoiceFastPathFacts {
        var facts = VoiceFastPathFacts()
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication else { return facts }
        let processIdentifier = frontmostApplication.processIdentifier
        let needsFocusedElement: Bool
        switch command {
        case .key(let keyCommand): needsFocusedElement = keyCommand.actsOnFocusedField
        case .readAloud, .startDictation: needsFocusedElement = true
        default: needsFocusedElement = false
        }
        let focusedElement = needsFocusedElement ? TypeForMeAccessibility.focusedElement(processIdentifier: processIdentifier) : nil
        facts.frontmost = ActionExecutor.facts(processIdentifier: processIdentifier, element: focusedElement, groundingElement: nil)
        if case .key(let keyCommand) = command, keyCommand == .closeTab || keyCommand == .closeWindow {
            facts.frontWindowHasUnsavedChanges = Self.frontWindowHasUnsavedChanges(processIdentifier: processIdentifier, title: facts.frontmost?.windowTitle)
        }
        if case .media = command {
            facts.isNetflixOrSafariLikelyPlaying = Self.isNetflixOrSafariLikelyPlaying(frontmost: facts.frontmost)
        }
        return facts
    }

    /// AXDocument edited (some apps expose AXEdited / AXModified), or "— Edited" in the title.
    static func frontWindowHasUnsavedChanges(processIdentifier: pid_t, title: String?) -> Bool {
        if VoiceFastPathFacts.titleShowsUnsavedChanges(title) { return true }
        guard let window = ActionExecutor.focusedWindow(processIdentifier: processIdentifier) else { return false }
        for attributeName in ["AXEdited", "AXModified", "AXIsDocumentEdited"] where TypeForMeAccessibility.boolAttribute(attributeName, of: window) == true {
            return true
        }
        return false
    }

    /// Safari in front, or any Safari / browser window titled with Netflix.
    static func isNetflixOrSafariLikelyPlaying(frontmost: ActionTargetFacts?) -> Bool {
        // Media keys reach whatever is playing, so Safari in front still counts here whatever "leave Safari alone" says.
        if let frontmost, ActionTierClassifier.isProtectedFromActions(frontmost, leavesSafariAlone: true) { return true }
        let browserBundleIdentifiers = Set(ActionBrowserChoice.knownBrowsers.map(\.bundleIdentifier)).union(ActionTierClassifier.safariBundleIdentifiers)
        for runningApplication in NSWorkspace.shared.runningApplications where browserBundleIdentifiers.contains(runningApplication.bundleIdentifier ?? "") {
            let applicationElement = TypeForMeAccessibility.applicationElement(processIdentifier: runningApplication.processIdentifier)
            for window in TypeForMeAccessibility.elementArrayAttribute(kAXWindowsAttribute, of: applicationElement).prefix(20) {
                if TypeForMeAccessibility.stringAttribute(kAXTitleAttribute, of: window)?.lowercased().contains("netflix") == true { return true }
            }
        }
        return false
    }

    // MARK: - Perform

    func perform(_ command: VoiceFastPathCommand, transcript: String) async -> VoiceFastPathOutcome {
        switch command {
        case .volumeUp: return changeVolume(by: 0.1, command: command)
        case .volumeDown: return changeVolume(by: -0.1, command: command)
        case .volumeSet(let percent): return setVolume(Float(percent) / 100, command: command)
        case .mute: return setMuted(true, command: command)
        case .unmute: return setMuted(false, command: command)
        case .brightnessUp: return changeBrightness(by: 0.1)
        case .brightnessDown: return changeBrightness(by: -0.1)
        case .media(let mediaKey, _): return pressMediaKey(mediaKey, command: command)
        case .window(let windowCommand): return moveFrontWindow(windowCommand, command: command)
        case .switchToApp(let name): return switchToApplication(named: name, command: command)
        case .openApp(let name): return openApplication(named: name, command: command)
        case .openItem(let name, let kind): return await openItem(named: name, kind: kind, command: command)
        case .key(let keyCommand):
            postKey(keyCommand.keyCombo)
            return .done(detail: "pressed \(keyCommand.keyCombo.displayText)", acknowledgement: command.acknowledgement())
        case .scroll(let scrollCommand): return scroll(scrollCommand, command: command)
        case .missionControl: return openMissionControl(arguments: [], command: command)
        case .showDesktop: return openMissionControl(arguments: ["1"], command: command)
        case .readAloud: return readSelectionAloud()
        case .screenshot(let target): return await takeScreenshot(target: target, command: command)
        case .lockScreen:
            // Only reached after the owner's yes (VoiceCommandController's confirm).
            postKey(ActionKeyCombo(modifiers: [.control, .command], key: "q", virtualKeyCode: UInt16(kVK_ANSI_Q)))
            return .done(detail: "locked the screen (ctrl+cmd+q)", acknowledgement: command.acknowledgement())
        case .startDictation, .stopDictation:
            return .done(detail: "dictation mode", acknowledgement: command.acknowledgement())
        }
    }

    // MARK: Volume (CoreAudio, default output)

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static var mainVolumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func currentVolume() -> Float? {
        guard let deviceID = defaultOutputDeviceID() else { return nil }
        var propertyAddress = Self.mainVolumeAddress
        var volume: Float32 = 0
        var propertySize = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &volume) == noErr ? volume : nil
    }

    private func setVolume(_ volume: Float, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        guard let deviceID = defaultOutputDeviceID() else { return .failed(reason: "no output device", spokenLine: "No speaker to change.") }
        var propertyAddress = Self.mainVolumeAddress
        var isSettable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &propertyAddress, &isSettable) == noErr, isSettable.boolValue else {
            return .failed(reason: "this output's volume can't be set", spokenLine: "Can't change this speaker's volume.")
        }
        var newVolume = Float32(min(1, max(0, volume)))
        let status = AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &newVolume)
        guard status == noErr else { return .failed(reason: "CoreAudio \(status)", spokenLine: "Couldn't change the volume.") }
        // Setting a volume also unmutes (as the volume keys do).
        if newVolume > 0 { _ = writeMute(false, deviceID: deviceID) }
        let percent = Int((newVolume * 100).rounded())
        return .done(detail: "volume \(percent)%", acknowledgement: command.acknowledgement(volumePercentAfter: percent))
    }

    private func changeVolume(by delta: Float, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        guard let volume = currentVolume() else { return .failed(reason: "volume unreadable", spokenLine: "Can't change this speaker's volume.") }
        // Steps land on tens (37 → 40 up, 37 → 30 down).
        let stepped = delta > 0 ? (floor(volume * 10 + 0.001) + 1) / 10 : (ceil(volume * 10 - 0.001) - 1) / 10
        return setVolume(stepped, command: command)
    }

    private func writeMute(_ muted: Bool, deviceID: AudioDeviceID) -> OSStatus {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                                         mElement: kAudioObjectPropertyElementMain)
        var muteValue: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(deviceID, &propertyAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteValue)
    }

    private func setMuted(_ muted: Bool, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        guard let deviceID = defaultOutputDeviceID() else { return .failed(reason: "no output device", spokenLine: "No speaker to change.") }
        let status = writeMute(muted, deviceID: deviceID)
        guard status == noErr else { return .failed(reason: "mute not supported (\(status))", spokenLine: "Can't mute this speaker.") }
        return .done(detail: muted ? "muted" : "unmuted", acknowledgement: command.acknowledgement())
    }

    // MARK: Brightness (built-in displays only)

    private typealias DisplayServicesGetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias DisplayServicesSetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private func changeBrightness(by delta: Float) -> VoiceFastPathOutcome {
        var displayCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &displayIDs, &displayCount)
        let builtInDisplays = displayIDs.prefix(Int(displayCount)).filter { CGDisplayIsBuiltin($0) != 0 }
        guard !builtInDisplays.isEmpty,
              let frameworkHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let getSymbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") else {
            return .failed(reason: "no built-in display (external displays don't take brightness from macOS)",
                           spokenLine: "Can't change brightness on these displays.")
        }
        let getBrightness = unsafeBitCast(getSymbol, to: DisplayServicesGetBrightness.self)
        let setBrightness = unsafeBitCast(setSymbol, to: DisplayServicesSetBrightness.self)
        var changedCount = 0
        for displayID in builtInDisplays {
            var brightness: Float = 0
            guard getBrightness(displayID, &brightness) == 0 else { continue }
            if setBrightness(displayID, min(1, max(0.05, brightness + delta))) == 0 { changedCount += 1 }
        }
        guard changedCount > 0 else { return .failed(reason: "DisplayServices refused", spokenLine: "Couldn't change the brightness.") }
        return .done(detail: "brightness \(delta > 0 ? "up" : "down")", acknowledgement: "Done.")
    }

    // MARK: Media keys

    /// NX_KEYTYPE_PLAY / NEXT / PREVIOUS as system-defined events (what the keyboard's media keys send), tagged.
    private func pressMediaKey(_ mediaKey: VoiceMediaKey, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        let keyType: Int
        switch mediaKey {
        // IOKit ev_keymap.h: NX_KEYTYPE_PLAY 16, NX_KEYTYPE_NEXT 17, NX_KEYTYPE_PREVIOUS 18.
        case .playPause: keyType = 16
        case .next: keyType = 17
        case .previous: keyType = 18
        }
        for isKeyDown in [true, false] {
            let keyState = isKeyDown ? 0xA : 0xB
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                                 modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(keyState << 8)),
                                                 timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                                 data1: (keyType << 16) | (keyState << 8), data2: -1),
                  let cgEvent = event.cgEvent else {
                return .failed(reason: "couldn't make the media key event", spokenLine: "Couldn't do that.")
            }
            SyntheticEvents.stamp(cgEvent)
            cgEvent.post(tap: .cghidEventTap)
        }
        return .done(detail: "media key \(mediaKey.rawValue)", acknowledgement: command.acknowledgement())
    }

    // MARK: Windows (AX position / size)

    private func moveFrontWindow(_ windowCommand: VoiceWindowCommand, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let window = ActionExecutor.focusedWindow(processIdentifier: frontmostApplication.processIdentifier),
              let windowFrameCG = TypeForMeAccessibility.frameCG(of: window) else {
            return .failed(reason: "no front window", spokenLine: "No window to move.")
        }
        if windowCommand == .minimize {
            let status = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            return status == .success ? .done(detail: "minimized", acknowledgement: command.acknowledgement())
                                      : .failed(reason: "AX \(status.rawValue)", spokenLine: "Couldn't minimize it.")
        }
        let screensLeftToRight = NSScreen.ownerScreens.sorted { $0.frame.minX < $1.frame.minX }
        let currentScreen = Self.screen(containingCG: CGPoint(x: windowFrameCG.midX, y: windowFrameCG.midY)) ?? NSScreen.main
        guard let currentScreen else { return .failed(reason: "no screen", spokenLine: "Couldn't find the screen.") }
        let targetScreen: NSScreen
        switch windowCommand {
        case .moveToScreenNumber(let number):
            guard number >= 1, number <= screensLeftToRight.count else {
                return .failed(reason: "only \(screensLeftToRight.count) screens", spokenLine: "There's no screen \(number).")
            }
            targetScreen = screensLeftToRight[number - 1]
        case .moveToScreenOnLeft, .moveToScreenOnRight, .moveToNextScreen:
            let currentIndex = screensLeftToRight.firstIndex(of: currentScreen) ?? 0
            let offset = windowCommand == .moveToScreenOnLeft ? -1 : 1
            let targetIndex = windowCommand == .moveToNextScreen ? (currentIndex + 1) % screensLeftToRight.count : currentIndex + offset
            guard screensLeftToRight.indices.contains(targetIndex), targetIndex != currentIndex else {
                return .failed(reason: "no screen that way", spokenLine: "No screen that way.")
            }
            targetScreen = screensLeftToRight[targetIndex]
        default:
            targetScreen = currentScreen
        }
        let visibleFrameCG = Self.cgRect(fromCocoa: targetScreen.visibleFrame)
        let newFrameCG: CGRect
        switch windowCommand {
        case .snapLeftHalf:
            newFrameCG = CGRect(x: visibleFrameCG.minX, y: visibleFrameCG.minY, width: (visibleFrameCG.width / 2).rounded(), height: visibleFrameCG.height)
        case .snapRightHalf:
            let halfWidth = (visibleFrameCG.width / 2).rounded()
            newFrameCG = CGRect(x: visibleFrameCG.maxX - halfWidth, y: visibleFrameCG.minY, width: halfWidth, height: visibleFrameCG.height)
        case .maximize:
            newFrameCG = visibleFrameCG
        default:
            // Another screen: the same place relative to the screen, made to fit.
            let sourceFrameCG = Self.cgRect(fromCocoa: currentScreen.visibleFrame)
            let width = min(windowFrameCG.width, visibleFrameCG.width)
            let height = min(windowFrameCG.height, visibleFrameCG.height)
            let relativeX = sourceFrameCG.width > width ? (windowFrameCG.minX - sourceFrameCG.minX) / (sourceFrameCG.width - width) : 0
            let relativeY = sourceFrameCG.height > height ? (windowFrameCG.minY - sourceFrameCG.minY) / (sourceFrameCG.height - height) : 0
            newFrameCG = CGRect(x: visibleFrameCG.minX + max(0, min(1, relativeX)) * (visibleFrameCG.width - width),
                                y: visibleFrameCG.minY + max(0, min(1, relativeY)) * (visibleFrameCG.height - height), width: width, height: height)
        }
        // Position, size, position again: some apps clamp the size to the old screen first.
        setPosition(newFrameCG.origin, of: window)
        setSize(newFrameCG.size, of: window)
        setPosition(newFrameCG.origin, of: window)
        return .done(detail: "window → \(Int(newFrameCG.minX)),\(Int(newFrameCG.minY)) \(Int(newFrameCG.width))×\(Int(newFrameCG.height))",
                     acknowledgement: command.acknowledgement())
    }

    private func setPosition(_ point: CGPoint, of window: AXUIElement) {
        var position = point
        if let value = AXValueCreate(.cgPoint, &position) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) }
    }

    private func setSize(_ size: CGSize, of window: AXUIElement) {
        var newSize = size
        if let value = AXValueCreate(.cgSize, &newSize) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) }
    }

    /// Cocoa (bottom-left origin) → CG global (top-left of the primary screen).
    static func cgRect(fromCocoa cocoaRect: CGRect) -> CGRect {
        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: cocoaRect.minX, y: primaryScreenHeight - cocoaRect.maxY, width: cocoaRect.width, height: cocoaRect.height)
    }

    static func screen(containingCG point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { cgRect(fromCocoa: $0.frame).contains(point) }
    }

    // MARK: Apps

    private func switchToApplication(named name: String, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        let regularApplications = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        let candidates = regularApplications.map { ActionApplicationCandidate(name: $0.localizedName ?? "", bundleIdentifier: $0.bundleIdentifier, path: $0.bundleURL?.path) }
        if let match = ActionAppNameMatcher.bestMatch(name: name, bundleIdentifier: nil, candidates: candidates),
           let runningApplication = regularApplications.first(where: { $0.bundleIdentifier == match.bundleIdentifier && $0.localizedName == match.name }) {
            if Self.isProtectedApplication(bundleIdentifier: runningApplication.bundleIdentifier, name: runningApplication.localizedName), !Self.namesSafariOrNetflix(name) {
                return .failed(reason: "Safari is left alone unless named", spokenLine: "I leave Safari alone.")
            }
            runningApplication.activate()
            return .done(detail: "switched to \(match.name)", acknowledgement: command.acknowledgement())
        }
        // Not running: open it.
        return openApplication(named: name, command: command)
    }

    private func openApplication(named name: String, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        guard let candidate = ActionExecutor.findApplication(name: name, bundleIdentifier: nil), let path = candidate.path else {
            return .notHandled(reason: "no app called \u{201C}\(name)\u{201D}")
        }
        if candidate.path.map({ URL(fileURLWithPath: $0).standardizedFileURL }) == Bundle.main.bundleURL.standardizedFileURL {
            return .failed(reason: "that's Clicky", spokenLine: "That's me.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, error in
            if let error { print("⚠️ Fast path: couldn't open \(candidate.name): \(error.localizedDescription)") }
        }
        return .done(detail: "opened \(candidate.name)", acknowledgement: command.acknowledgement())
    }

    static func isProtectedApplication(bundleIdentifier: String?, name: String?) -> Bool {
        ActionTierClassifier.isSafari(ActionTargetFacts(bundleIdentifier: bundleIdentifier, applicationName: name))
    }

    static func namesSafariOrNetflix(_ text: String) -> Bool {
        ActionWordMatch.containsWord(in: text, anyOf: ["safari", "netflix"])
    }

    // MARK: Files and folders (Spotlight, outside protected folders)

    /// Home's top level (listed directly), plus ~/Projects and /Applications through Spotlight. Desktop,
    /// Documents and Downloads only with v2.code.searchProtectedFolders (macOS asks the owner for those).
    private func openItem(named name: String, kind: VoiceOpenItemKind, command: VoiceFastPathCommand) async -> VoiceFastPathOutcome {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        let protectedFolderURLs = ["Desktop", "Documents", "Downloads"].map { homeURL.appendingPathComponent($0, isDirectory: true).standardizedFileURL.path }
        let searchesProtectedFolders = ClickySettings.searchesProtectedFolders
        var candidateURLs: [URL] = []
        if let homeEntries = try? FileManager.default.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            candidateURLs += homeEntries.filter { searchesProtectedFolders || !protectedFolderURLs.contains($0.standardizedFileURL.path) }
        }
        var searchScopes = [homeURL.appendingPathComponent("Projects", isDirectory: true), URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if searchesProtectedFolders { searchScopes += protectedFolderURLs.map { URL(fileURLWithPath: $0, isDirectory: true) } }
        candidateURLs += await VoiceSpotlightSearch.find(nameContaining: name, scopes: searchScopes.filter { FileManager.default.fileExists(atPath: $0.path) },
                                                          timeoutSeconds: 1.0)
        let isAllowed: (URL) -> Bool = { url in
            let path = url.standardizedFileURL.path
            return searchesProtectedFolders || !protectedFolderURLs.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        guard let bestURL = VoiceItemRanking.best(of: candidateURLs.filter(isAllowed), spokenName: name, kind: kind) else {
            return .notHandled(reason: "no \(kind == .folder ? "folder" : "file") called \u{201C}\(name)\u{201D} outside the protected folders")
        }
        NSWorkspace.shared.open(bestURL)
        return .done(detail: "opened \(bestURL.path.replacingOccurrences(of: homeURL.path, with: "~"))", acknowledgement: command.acknowledgement())
    }

    // MARK: Keys and scrolling

    private func postKey(_ combo: ActionKeyCombo) {
        // Theo has its own screen: the key goes to the front app's process without warping or refocusing anything.
        if BackgroundInput.isActive, let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            BackgroundInput.postKey(processIdentifier: frontmostProcessIdentifier, combo: combo)
            return
        }
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        for isKeyDown in [true, false] {
            guard let event = SyntheticEvents.keyEvent(virtualKey: CGKeyCode(combo.virtualKeyCode), keyDown: isKeyDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func scroll(_ scrollCommand: VoiceScrollCommand, command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        if let keyCombo = scrollCommand.keyCombo {
            postKey(keyCombo)
            return .done(detail: "pressed \(keyCombo.displayText)", acknowledgement: command.acknowledgement())
        }
        if BackgroundInput.isActive, let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            // Posted to the front app's process at its window's middle: the real pointer never moves.
            let windowFrameCG = ActionExecutor.focusedWindow(processIdentifier: frontmostApplication.processIdentifier).flatMap(TypeForMeAccessibility.frameCG)
            let scrollPoint = windowFrameCG.map { CGPoint(x: $0.midX, y: $0.midY) } ?? (CGEvent(source: nil)?.location ?? .zero)
            let lines: Int32 = scrollCommand == .up ? 12 : -12
            if BackgroundInput.scroll(processIdentifier: frontmostApplication.processIdentifier, at: scrollPoint, verticalLines: lines) != nil {
                return .done(detail: "scrolled \(scrollCommand.rawValue)", acknowledgement: command.acknowledgement())
            }
        }
        // Scroll events go to the window under the pointer: if it isn't over the front window, move it there (tagged).
        let mouseLocationCG = CGEvent(source: nil)?.location ?? .zero
        var scrollPointCG = mouseLocationCG
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           let window = ActionExecutor.focusedWindow(processIdentifier: frontmostApplication.processIdentifier),
           let windowFrameCG = TypeForMeAccessibility.frameCG(of: window), !windowFrameCG.contains(mouseLocationCG) {
            scrollPointCG = CGPoint(x: windowFrameCG.midX, y: windowFrameCG.midY)
            SyntheticEvents.mouseEvent(.mouseMoved, at: scrollPointCG)?.post(tap: .cghidEventTap)
        }
        let lines: Int32 = scrollCommand == .up ? 12 : -12
        guard let event = CGEvent(scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState), units: .line, wheelCount: 1,
                                  wheel1: lines, wheel2: 0, wheel3: 0) else {
            return .failed(reason: "no scroll event", spokenLine: "Couldn't scroll.")
        }
        SyntheticEvents.stamp(event)
        event.location = scrollPointCG
        event.post(tap: .cghidEventTap)
        return .done(detail: "scrolled \(scrollCommand.rawValue)", acknowledgement: command.acknowledgement())
    }

    // MARK: Mission Control and the desktop

    private func openMissionControl(arguments: [String], command: VoiceFastPathCommand) -> VoiceFastPathOutcome {
        let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        guard FileManager.default.fileExists(atPath: missionControlURL.path) else {
            return .failed(reason: "Mission Control.app missing", spokenLine: "Couldn't open Mission Control.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // "1" is Mission Control's show-desktop mode.
        configuration.arguments = arguments
        NSWorkspace.shared.openApplication(at: missionControlURL, configuration: configuration) { _, error in
            if let error { print("⚠️ Fast path: Mission Control: \(error.localizedDescription)") }
        }
        return .done(detail: arguments.isEmpty ? "mission control" : "show desktop", acknowledgement: command.acknowledgement())
    }

    // MARK: Read aloud

    private func readSelectionAloud() -> VoiceFastPathOutcome {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let focusedElement = TypeForMeAccessibility.focusedElement(processIdentifier: frontmostApplication.processIdentifier) else {
            return .failed(reason: "nothing focused", spokenLine: "Select some text first.")
        }
        if IsSecureEventInputEnabled() || TypeForMeAccessibility.stringAttribute(kAXSubroleAttribute, of: focusedElement) == TypeForMePolicy.secureTextFieldSubrole {
            return .failed(reason: "password field", spokenLine: "That's a password field.")
        }
        let selectedText = TypeForMeAccessibility.stringAttribute(kAXSelectedTextAttribute, of: focusedElement)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = selectedText.isEmpty ? (TypeForMeAccessibility.value(of: focusedElement)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") : selectedText
        guard !text.isEmpty else { return .failed(reason: "no text", spokenLine: "Select some text first.") }
        // Long fields are read in part (the first 2,500 characters).
        let spokenText = text.count > 2500 ? String(text.prefix(2500)) : text
        companionManager.speakCodeModeLine(spokenText)
        return .done(detail: "reading \(spokenText.count) characters (\(selectedText.isEmpty ? "field text" : "selection"))", acknowledgement: "")
    }

    // MARK: Screenshot

    private func takeScreenshot(target: SnapshotTarget, command: VoiceFastPathCommand) async -> VoiceFastPathOutcome {
        do {
            let snapshotResult = try await SnapshotCapture.capture(request: SnapshotRequest(target: target), markRectsCG: [])
            return .done(detail: "saved \(snapshotResult.fileURL.lastPathComponent)", acknowledgement: command.acknowledgement())
        } catch {
            return .failed(reason: error.localizedDescription, spokenLine: "Couldn't take the screenshot.")
        }
    }

    // MARK: Dictation

    /// Types one dictated line into the focused field (AX first, else tagged unicode keys). Never into a
    /// secure field, a terminal or Clicky; nil on success, else why not.
    func typeDictatedText(_ text: String) async -> String? {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              let focusedElement = TypeForMeAccessibility.focusedElement(processIdentifier: frontmostApplication.processIdentifier) else {
            return "no text field is focused"
        }
        let facts = ActionExecutor.facts(processIdentifier: frontmostApplication.processIdentifier, element: focusedElement, groundingElement: nil)
        if let refusal = VoiceFastPathPolicy.dictationRefusal(focused: facts) { return refusal }
        let valueBefore = TypeForMeAccessibility.value(of: focusedElement) ?? ""
        let needsLeadingSpace = !(valueBefore.isEmpty || valueBefore.last?.isWhitespace == true)
        let insertedText = (needsLeadingSpace ? " " : "") + text
        if TypeForMeAccessibility.setSelectedText(insertedText, of: focusedElement),
           InsertionVerification.evaluate(valueBefore: valueBefore, valueAfter: TypeForMeAccessibility.value(of: focusedElement), insertedText: insertedText) != .unchanged {
            return nil
        }
        guard let chunks = UnicodeTypingChunker.chunks(of: insertedText) else { return "that text can't be typed there" }
        for chunk in chunks {
            // Re-checked per chunk: a password prompt may have appeared.
            if IsSecureEventInputEnabled() { return "a password prompt has secure input on" }
            guard TypeForMeSyntheticEvents.areNoModifiersHeld(CGEventSource.flagsState(.hidSystemState)) else { return "a modifier key was held down" }
            for event in TypeForMeSyntheticEvents.unicodeEvents(for: chunk) { event.post(tap: .cghidEventTap) }
            try? await Task.sleep(nanoseconds: ActionExecutor.delayBetweenUnicodeChunks)
        }
        return nil
    }
}

/// Best file or folder for a spoken name: exact name (extension ignored), then prefix, then contained;
/// shallower paths first. Folders only for "folder", files only for "file".
enum VoiceItemRanking {
    static func best(of urls: [URL], spokenName: String, kind: VoiceOpenItemKind) -> URL? {
        let wantedName = normalized(spokenName)
        guard !wantedName.isEmpty else { return nil }
        var bestURL: URL?
        var bestScore = Int.max
        var seenPaths: Set<String> = []
        for url in urls where seenPaths.insert(url.standardizedFileURL.path).inserted {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isPackage = url.pathExtension == "app"
            switch kind {
            case .folder where !isDirectory || isPackage: continue
            case .file where isDirectory && !isPackage: continue
            default: break
            }
            let itemName = normalized(url.deletingPathExtension().lastPathComponent)
            let matchRank: Int
            if itemName == wantedName { matchRank = 0 } else if itemName.hasPrefix(wantedName) { matchRank = 1 } else if itemName.contains(wantedName) { matchRank = 2 } else { continue }
            let score = matchRank * 1000 + url.pathComponents.count
            if score < bestScore {
                bestScore = score
                bestURL = url
            }
        }
        return bestURL
    }

    static func normalized(_ text: String) -> String {
        ActionWordMatch.normalized(text).filter { $0.isLetter || $0.isNumber }
    }
}

/// One NSMetadataQuery by display name inside `scopes`, finished or cut at the timeout.
@MainActor
enum VoiceSpotlightSearch {
    static func find(nameContaining name: String, scopes: [URL], timeoutSeconds: TimeInterval) async -> [URL] {
        guard !scopes.isEmpty else { return [] }
        let query = NSMetadataQuery()
        let escapedName = name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "*", with: "")
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(escapedName)*")
        query.searchScopes = scopes
        return await withCheckedContinuation { (continuation: CheckedContinuation<[URL], Never>) in
            var observer: NSObjectProtocol?
            var hasResumed = false
            let finish: @MainActor () -> Void = {
                guard !hasResumed else { return }
                hasResumed = true
                query.stop()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                let urls = (0..<min(query.resultCount, 200)).compactMap { index -> URL? in
                    (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey).flatMap { $0 as? String }.map { URL(fileURLWithPath: $0) }
                }
                continuation.resume(returning: urls)
            }
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                MainActor.assumeIsolated { finish() }
            }
            if !query.start() {
                finish()
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                finish()
            }
        }
    }
}
