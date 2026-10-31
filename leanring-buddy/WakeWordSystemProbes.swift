//
//  WakeWordSystemProbes.swift
//  leanring-buddy
//
//  P7 wake word, the system reads behind the auto-pause and the CPU figure:
//  - MicrophoneInUseProbe: is another app capturing from the mic (a call, a
//    meeting, a voice memo)? macOS 14's CoreAudio process objects say which
//    processes run input; Clicky itself and Siri's always-on listener don't
//    count. Fallback: the default input device's IsRunningSomewhere, read
//    only while Clicky's own wake engine is stopped.
//  - isDefaultInputBluetooth: a Bluetooth headset mic would drop the
//    headset into call mode while the wake word holds it open, so the wake
//    word pauses instead.
//  - ProcessCPUTimeProbe: this process's CPU seconds (task_info: live
//    threads + finished ones), and the on-device speech service's (the
//    recognizer runs out of process: localspeechrecognition and
//    com.apple.siri.embeddedspeech).
//  Read-only; nothing is requested or changed.
//

import AudioToolbox
import CoreAudio
import Darwin
import Foundation

enum MicrophoneInUseProbe {
    /// Processes whose input never pauses the wake word.
    private static let ignoredBundleIdentifierPrefixes = ["com.apple.corespeech", "com.apple.assistantd", "com.apple.siri", "com.apple.Siri"]

    /// `isOwnEngineRunning`: Clicky's wake engine is capturing right now
    /// (then the device-level fallback can't tell who else is).
    static func isMicrophoneInUseByAnotherProcess(isOwnEngineRunning: Bool) -> Bool {
        if let processObjectIDs = processObjectIDs() {
            let ownProcessIdentifier = getpid()
            for processObjectID in processObjectIDs {
                guard uint32Property(of: processObjectID, selector: kAudioProcessPropertyIsRunningInput) == 1 else { continue }
                guard let processIdentifier = pidProperty(of: processObjectID), processIdentifier != ownProcessIdentifier else { continue }
                let bundleIdentifier = bundleIdentifierProperty(of: processObjectID) ?? ""
                if ignoredBundleIdentifierPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) { continue }
                return true
            }
            return false
        }
        guard !isOwnEngineRunning, let inputDeviceID = defaultInputDeviceID() else { return false }
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var isRunningSomewhere: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(inputDeviceID, &propertyAddress, 0, nil, &propertySize, &isRunningSomewhere)
        return status == noErr && isRunningSomewhere != 0
    }

    /// The default input device is Bluetooth (AirPods and other headsets):
    /// opening its mic switches the headset to call mode.
    static func isDefaultInputBluetooth() -> Bool {
        guard let inputDeviceID = defaultInputDeviceID() else { return false }
        let transportType = uint32Property(of: inputDeviceID, selector: kAudioDevicePropertyTransportType)
        return transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// A wired mic to use instead of a Bluetooth default (built-in first, then USB/other wired), or nil.
    /// The wake engine pins it so AirPods never switch to call mode. Virtual and aggregate devices are skipped.
    static func wiredInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var propertySize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &propertyAddress, 0, nil, &propertySize) == noErr else { return nil }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(propertySize) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObjectID, &propertyAddress, 0, nil, &propertySize, &deviceIDs) == noErr else { return nil }
        let excluded: Set<UInt32> = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
                                     kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate]
        let inputDevices = deviceIDs.filter { deviceID in
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(deviceID, &streamsAddress, 0, nil, &streamsSize) == noErr && streamsSize > 0
                && !excluded.contains(uint32Property(of: deviceID, selector: kAudioDevicePropertyTransportType) ?? kAudioDeviceTransportTypeVirtual)
        }
        return inputDevices.first { uint32Property(of: $0, selector: kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn }
            ?? inputDevices.first
    }

    private static func processObjectIDs() -> [AudioObjectID]? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var propertySize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &propertyAddress, 0, nil, &propertySize) == noErr else { return nil }
        let objectCount = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        guard objectCount > 0 else { return [] }
        var objectIDs = [AudioObjectID](repeating: 0, count: objectCount)
        guard AudioObjectGetPropertyData(systemObjectID, &propertyAddress, 0, nil, &propertySize, &objectIDs) == noErr else { return nil }
        return Array(objectIDs.prefix(Int(propertySize) / MemoryLayout<AudioObjectID>.size))
    }

    private static func uint32Property(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var propertyValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &propertyValue) == noErr ? propertyValue : nil
    }

    private static func pidProperty(of objectID: AudioObjectID) -> pid_t? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var processIdentifier: pid_t = 0
        var propertySize = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &processIdentifier) == noErr ? processIdentifier : nil
    }

    private static func bundleIdentifierProperty(of objectID: AudioObjectID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bundleIdentifier: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &bundleIdentifier) == noErr,
              let bundleIdentifier else { return nil }
        return bundleIdentifier.takeRetainedValue() as String
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var inputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &inputDeviceID)
        return status == noErr && inputDeviceID != 0 ? inputDeviceID : nil
    }
}

/// P8: which input device a mic engine really runs on (name, UID, sample rate,
/// transport), so the wake word can listen on the same mic push-to-talk uses
/// and wakeStatus can say what it hears through. Read-only.
struct AudioInputDeviceInfo: Equatable {
    let deviceID: AudioDeviceID
    let name: String
    let uid: String
    let nominalSampleRate: Double
    let isBluetooth: Bool

    var statusDictionary: [String: Any] {
        ["name": name, "uid": uid, "sampleRate": nominalSampleRate, "bluetooth": isBluetooth, "id": Int(deviceID)]
    }

    static func read(deviceID: AudioDeviceID) -> AudioInputDeviceInfo? {
        guard deviceID != 0 else { return nil }
        let transportType = uint32Property(of: deviceID, selector: kAudioDevicePropertyTransportType)
        return AudioInputDeviceInfo(deviceID: deviceID,
                                    name: stringProperty(of: deviceID, selector: kAudioObjectPropertyName) ?? "device \(deviceID)",
                                    uid: stringProperty(of: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "",
                                    nominalSampleRate: float64Property(of: deviceID, selector: kAudioDevicePropertyNominalSampleRate) ?? 0,
                                    isBluetooth: transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE)
    }

    static func defaultInput() -> AudioInputDeviceInfo? {
        MicrophoneInUseProbe.defaultInputDeviceID().flatMap { read(deviceID: $0) }
    }

    /// The device an engine's input unit is set to (its CurrentDevice), else nil.
    static func current(of audioUnit: AudioUnit?) -> AudioInputDeviceInfo? {
        guard let audioUnit else { return nil }
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID, &propertySize)
        return status == noErr ? read(deviceID: deviceID) : nil
    }

    /// The live device with this UID that still has input streams, else nil.
    static func inputDeviceID(forUID uid: String) -> AudioDeviceID? {
        var translatedDeviceID = AudioDeviceID(0)
        var cfUID = uid as CFString
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                         mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, UInt32(MemoryLayout<CFString>.size),
                                       uidPointer, &propertySize, &translatedDeviceID)
        }
        guard status == noErr, translatedDeviceID != 0 else { return nil }
        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                        mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(translatedDeviceID, &streamsAddress, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { return nil }
        return translatedDeviceID
    }

    private static func uint32Property(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var propertyValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &propertyValue) == noErr ? propertyValue : nil
    }

    private static func float64Property(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> Double? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var propertyValue: Float64 = 0
        var propertySize = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &propertyValue) == noErr ? propertyValue : nil
    }

    private static func stringProperty(of objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var propertySize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &propertySize, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// P8: the input device push-to-talk last captured from (set by BuddyDictationManager
/// when its engine starts). The wake word listens on the same mic when it can.
@MainActor
enum PushToTalkInputDeviceRecord {
    private(set) static var lastDevice: AudioInputDeviceInfo?
    private(set) static var lastRecordedDate: Date?

    static func record(_ device: AudioInputDeviceInfo?) {
        guard let device else { return }
        if lastDevice != device { print("🎙️ Push-to-talk input: \(device.name) (\(device.uid), \(Int(device.nominalSampleRate)) Hz)") }
        lastDevice = device
        lastRecordedDate = Date()
    }
}

enum ProcessCPUTimeProbe {
    /// CPU seconds this process has used: live threads (TASK_THREAD_TIMES_INFO)
    /// plus threads that already exited (MACH_TASK_BASIC_INFO).
    static func currentProcessCPUSeconds() -> TimeInterval {
        var liveThreadTimes = task_thread_times_info_data_t()
        var liveThreadTimesCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let liveStatus = withUnsafeMutablePointer(to: &liveThreadTimes) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(liveThreadTimesCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveThreadTimesCount)
            }
        }
        var basicInfo = mach_task_basic_info_data_t()
        var basicInfoCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let basicStatus = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicInfoCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicInfoCount)
            }
        }
        func seconds(_ time: time_value_t) -> TimeInterval { TimeInterval(time.seconds) + TimeInterval(time.microseconds) / 1_000_000 }
        var totalSeconds: TimeInterval = 0
        if liveStatus == KERN_SUCCESS { totalSeconds += seconds(liveThreadTimes.user_time) + seconds(liveThreadTimes.system_time) }
        if basicStatus == KERN_SUCCESS { totalSeconds += seconds(basicInfo.user_time) + seconds(basicInfo.system_time) }
        return totalSeconds
    }

    /// The on-device recognizer's process names (it runs outside Clicky).
    /// localspeechrecognition (Speech.framework's XPC service) hands audio to the
    /// embedded recognizer, com.apple.siri.embeddedspeech.
    static let speechServiceProcessNamePrefixes = ["localspeechrecognition", "com.apple.siri.embeddedspeech", "speechrecognitiond"]

    /// CPU seconds of the speech service processes this user can read; nil if none was found.
    static func speechServiceCPUSeconds() -> TimeInterval? {
        let processCount = proc_listallpids(nil, 0)
        guard processCount > 0 else { return nil }
        var processIdentifiers = [pid_t](repeating: 0, count: Int(processCount) + 32)
        let filledCount = proc_listallpids(&processIdentifiers, Int32(processIdentifiers.count * MemoryLayout<pid_t>.size))
        guard filledCount > 0 else { return nil }
        var timebaseInfo = mach_timebase_info_data_t()
        mach_timebase_info(&timebaseInfo)
        var totalSeconds: TimeInterval = 0
        var foundAny = false
        for processIdentifier in processIdentifiers.prefix(Int(filledCount)) where processIdentifier > 0 {
            var nameBuffer = [CChar](repeating: 0, count: 64)
            guard proc_name(processIdentifier, &nameBuffer, UInt32(nameBuffer.count)) > 0 else { continue }
            let processName = String(cString: nameBuffer)
            guard speechServiceProcessNamePrefixes.contains(where: { processName.hasPrefix($0) }) else { continue }
            var usage = rusage_info_v2()
            let status = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(processIdentifier, RUSAGE_INFO_V2, $0)
                }
            }
            guard status == 0 else { continue }
            // ri_*_time are mach ticks on Apple silicon (nanoseconds on Intel, where the timebase is 1/1).
            let ticks = Double(usage.ri_user_time + usage.ri_system_time)
            totalSeconds += ticks * Double(timebaseInfo.numer) / Double(timebaseInfo.denom) / 1_000_000_000
            foundAny = true
        }
        return foundAny ? totalSeconds : nil
    }
}
