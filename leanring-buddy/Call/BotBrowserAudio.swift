//
//  BotBrowserAudio.swift
//  leanring-buddy
//
//  The sound of a Space joined on Vello's own X account. Vello hears only the bot's browser, through a Core Audio
//  process tap on that browser and its helpers (Chromium plays a page's sound from a helper process, not the app), and
//  speaks to the virtual mic (BlackHole) through an engine of its own whose output is set to that device, so nothing
//  goes to the Mac's speakers unless "Also play Vello on this Mac" is on. The Mac's own mic isn't used.
//

import AudioToolbox
import AVFoundation
import ClickyCore
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Hears one app (and its helper processes) with a process tap, as mono float samples, whatever else plays on the Mac.
/// Helpers come and go (Chromium starts its audio helper when a page first plays), so the tapped set is checked every
/// second and a half and the tap made again when it changes.
final class BotBrowserAudioTap: @unchecked Sendable {
    private let browserBundleID: String
    private let browserAppPath: String?
    private let queue = DispatchQueue(label: "vello.bot-browser.tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    private var refreshTimer: Timer?
    private var tapFormat: AVAudioFormat?

    /// Mono float32 samples, on the tap's own queue.
    var onSamples: ((AVAudioPCMBuffer) -> Void)?
    /// Something went wrong making the tap, in words, on the main actor.
    var onProblem: ((String) -> Void)?
    private(set) var tappedProcessNames: [String] = []
    private(set) var lastError: String?
    /// Blocks heard since the start, and the loudest one, for `ownAccountStatus`.
    private let counters = TapCounters()

    init(browserBundleID: String, browserAppPath: String?) {
        self.browserBundleID = browserBundleID
        self.browserAppPath = browserAppPath
    }

    var buffersHeard: Int { counters.buffers }
    var loudestDecibels: Double { counters.loudest }

    @MainActor
    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @MainActor
    func stop() {
        isStopped = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        queue.async { [weak self] in self?.tearDown() }
        tappedProcesses = []
    }

    /// The browser's processes that make sound now: if they changed, the tap is made again with them.
    /// A tap is being made: making one can wait on macOS's privacy question, so it's made off the main thread (on the
    /// first try it held the whole app for a minute and a half).
    private var isBuilding = false
    private var isStopped = false

    @MainActor
    private func refresh() {
        guard !isBuilding, !isStopped else { return }
        let found = Self.audioProcesses().filter {
            BotBrowserChoice.processBelongs(processBundleID: $0.bundleID, processPath: $0.path, browserBundleID: browserBundleID, browserAppPath: browserAppPath)
        }
        let objects = found.map(\.object).sorted()
        guard objects != tappedProcesses else { return }
        isBuilding = true
        let names = found.map { ($0.path as NSString?)?.lastPathComponent ?? $0.bundleID ?? "pid \($0.pid)" }
        queue.async { [weak self] in
            guard let self else { return }
            self.tearDown()
            var failure: Error?
            if !objects.isEmpty {
                do { try self.build(processes: objects) } catch {
                    failure = error
                    self.tearDown()
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isBuilding = false
                    if self.isStopped { self.queue.async { self.tearDown() }; return }
                    self.tappedProcesses = objects
                    self.tappedProcessNames = names
                    if let failure {
                        self.lastError = failure.localizedDescription
                        callLog("📞 Space: couldn't hear the bot's browser: \(failure.localizedDescription)")
                        self.onProblem?("Vello can't hear the bot's browser: \(failure.localizedDescription)")
                    } else if !objects.isEmpty {
                        self.lastError = nil
                        callLog("📞 Space: hearing the bot's browser (\(objects.count) process\(objects.count == 1 ? "" : "es"): \(names.joined(separator: ", ")))")
                    }
                }
            }
        }
    }

    private struct TapError: LocalizedError {
        let errorDescription: String?
        init(_ what: String, _ status: OSStatus) { errorDescription = "\(what) failed (\(status))" }
    }

    /// On the tap's queue.
    private func build(processes: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Vello hears the bot's browser"
        // The browser stays audible as it was; Vello only listens in.
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTap)
        guard status == noErr else { throw TapError("Making the process tap", status) }
        tapID = newTap

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &streamDescription) else { throw TapError("Reading the tap's format", status) }
        tapFormat = format

        // A private device holding the tap, on the Mac's own output's clock.
        let outputUID = AudioDevices.defaultOutputUID ?? ""
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Vello bot browser",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        if !outputUID.isEmpty {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard status == noErr else { throw TapError("Making the tap's device", status) }
        aggregateID = newAggregate

        let counters = self.counters
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, inputData, _, _, _ in
            guard let self, let format = self.tapFormat,
                  let mono = Self.mono(of: inputData, format: format) else { return }
            counters.heard(mono)
            self.onSamples?(mono)
        }
        guard status == noErr, procID != nil else { throw TapError("Listening to the tap", status) }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError("Starting the tap", status) }
    }

    /// On the tap's queue.
    private func tearDown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// The tap's buffer (stereo, interleaved or not) as one mono float channel.
    private static func mono(of list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil), input.frameLength > 0,
              let source = input.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: input.frameLength), let target = output.floatChannelData?[0] else { return nil }
        let channels = Int(format.channelCount)
        let frames = Int(input.frameLength)
        if format.isInterleaved {
            let samples = source[0]
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                target[frame] = sum / Float(channels)
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += source[channel][frame] }
                target[frame] = sum / Float(channels)
            }
        }
        output.frameLength = input.frameLength
        return output
    }

    struct AudioProcess {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let path: String?
    }

    /// Every process Core Audio knows of (any that has opened audio), with its bundle id and program.
    static func audioProcesses() -> [AudioProcess] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.compactMap { object in
            var pidAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddress, 0, nil, &pidSize, &pid) == noErr else { return nil }
            let bundleID = AudioDevices.string(kAudioProcessPropertyBundleID, of: object)
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let path = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 ? String(cString: pathBuffer) : nil
            return AudioProcess(object: object, pid: pid, bundleID: bundleID, path: path)
        }
    }
}

/// How much the tap has heard, written from its queue and read from the main actor.
final class TapCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var heardBuffers = 0
    private var loudestLevel = -100.0

    var buffers: Int { lock.withLock { heardBuffers } }
    var loudest: Double { lock.withLock { loudestLevel } }

    func heard(_ buffer: AVAudioPCMBuffer) {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let level = 20 * log10(Double(max(sqrt(sum / Float(buffer.frameLength)), 0.000_01)))
        lock.withLock {
            heardBuffers += 1
            loudestLevel = max(loudestLevel, level)
        }
    }
}

/// Plays a call's voice on one output device of its own choosing (BlackHole, or the Mac's speakers for the monitor),
/// with an engine of its own so it never touches the hub's echo-cancelling one.
@MainActor
final class DeviceVoicePlayer {
    let channel: SharedEnginePlayerChannel
    private let engine = AVAudioEngine()
    private(set) var deviceName = "this Mac's speakers"

    init(channel: SharedEnginePlayerChannel) {
        self.channel = channel
    }

    /// `deviceUID` nil: the Mac's default output. `fullVolume`: always heard, even in a test profile (the virtual mic,
    /// which only the bot's browser hears); otherwise silent in a test profile like every call voice.
    func start(deviceUID: String?, fullVolume: Bool) throws {
        channel.fixedVolume = fullVolume ? 1 : nil
        engine.attach(channel.playerNode)
        engine.attach(channel.timePitchUnit)
        engine.connect(channel.playerNode, to: channel.timePitchUnit, format: SharedEnginePlayerChannel.playbackFormat)
        engine.connect(channel.timePitchUnit, to: engine.mainMixerNode, format: SharedEnginePlayerChannel.playbackFormat)
        if let deviceUID {
            guard let device = AudioDevices.device(uid: deviceUID) else {
                throw HandsFreeListeningSessionError(message: "The output for Vello's voice isn't connected.")
            }
            guard let unit = engine.outputNode.audioUnit else { throw HandsFreeListeningSessionError(message: "No output unit.") }
            var deviceID = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &deviceID,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw HandsFreeListeningSessionError(message: "Couldn't play to \(device.name) (\(status)).") }
            deviceName = device.name
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        channel.stop()
        engine.stop()
    }
}

/// Records a few seconds of one input device straight from Core Audio and says how loud it was: for checking that Vello's
/// voice really comes out of the virtual mic's input side, where the bot's browser listens (`ownAccountRecord`). Test use
/// only. Reading an input needs the Microphone permission.
@MainActor
enum DeviceInputCheck {
    static func record(deviceUID: String, seconds: Double, saveTo fileURL: URL?) async -> [String: Any] {
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "granted"
        case .denied, .restricted: microphone = "refused"
        default: microphone = "not asked"
        }
        guard let device = AudioDevices.inputs().first(where: { $0.uid == deviceUID || $0.name == deviceUID }) else {
            return ["error": "No input device \(deviceUID).", "microphonePermission": microphone]
        }
        let counters = TapCounters()
        let queue = DispatchQueue(label: "vello.device-input-check")
        var procID: AudioDeviceIOProcID?
        var streamDescription = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &streamDescription) == noErr,
              let format = AVAudioFormat(streamDescription: &streamDescription) else {
            return ["error": "Couldn't read \(device.name)'s input format.", "microphonePermission": microphone]
        }
        let file = fileURL.flatMap { try? AVAudioFile(forWriting: $0, settings: format.settings) }
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, queue) { _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil), buffer.frameLength > 0 else { return }
            try? file?.write(from: buffer)
            guard let samples = buffer.floatChannelData?[0],
                  let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
                  let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength), let target = copy.floatChannelData?[0] else { return }
            let stride = buffer.stride
            for frame in 0..<Int(buffer.frameLength) { target[frame] = samples[frame * stride] }
            copy.frameLength = buffer.frameLength
            counters.heard(copy)
        }
        guard status == noErr, let procID else { return ["error": "Couldn't listen to \(device.name) (\(status)).", "microphonePermission": microphone] }
        status = AudioDeviceStart(device.id, procID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device.id, procID)
            return ["error": "Couldn't start \(device.name) (\(status)).", "microphonePermission": microphone]
        }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        AudioDeviceStop(device.id, procID)
        AudioDeviceDestroyIOProcID(device.id, procID)
        return ["device": device.name, "buffers": counters.buffers, "loudestDecibels": counters.loudest, "silent": counters.loudest < -60,
                "file": fileURL?.path ?? "", "microphonePermission": microphone]
    }
}

/// Hears one app through ScreenCaptureKit's app-filtered audio: the other way to hear the bot's browser, which needs only
/// the Screen Recording permission the speaker names need anyway. `BotBrowserHearing.method` picks it or the process tap.
final class BotBrowserScreenAudio: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let browserBundleID: String
    private let browserAppPath: String?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "vello.bot-browser.sck-audio", qos: .userInteractive)
    private let counters = TapCounters()
    var onSamples: ((AVAudioPCMBuffer) -> Void)?
    var onProblem: ((String) -> Void)?
    private(set) var capturedAppNames: [String] = []
    private(set) var lastError: String?

    init(browserBundleID: String, browserAppPath: String?) {
        self.browserBundleID = browserBundleID
        self.browserAppPath = browserAppPath
    }

    var buffersHeard: Int { counters.buffers }
    var loudestDecibels: Double { counters.loudest }

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let apps = content.applications.filter {
                BotBrowserChoice.processBelongs(processBundleID: $0.bundleIdentifier, processPath: nil, browserBundleID: browserBundleID, browserAppPath: browserAppPath)
            }
            capturedAppNames = apps.map { "\($0.applicationName) (\($0.bundleIdentifier))" }
            guard let display = content.displays.first, !apps.isEmpty else {
                lastError = "The bot's browser isn't running."
                onProblem?("The bot's browser isn't running, so Vello can't hear the Space.")
                return
            }
            let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            // Audio is what's wanted: the picture is the smallest and slowest there is.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        } catch {
            lastError = error.localizedDescription
            onProblem?("Vello can't hear the bot's browser: \(error.localizedDescription)")
        }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastError = error.localizedDescription
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let mono = Self.mono(of: sampleBuffer) else { return }
        counters.heard(mono)
        onSamples?(mono)
    }

    /// ScreenCaptureKit's audio (float, one buffer per channel) as one mono float channel.
    private static func mono(of sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        var streamDescription = description
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr,
              let source = input.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false),
              let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames), let target = output.floatChannelData?[0] else { return nil }
        let channels = Int(format.channelCount)
        for frame in 0..<Int(frames) {
            var sum: Float = 0
            if format.isInterleaved {
                for channel in 0..<channels { sum += source[0][frame * channels + channel] }
            } else {
                for channel in 0..<channels { sum += source[channel][frame] }
            }
            target[frame] = sum / Float(channels)
        }
        output.frameLength = frames
        return output
    }
}

/// How the bot's browser is heard. Both heard Chromium's audio helper in `ownAccountProbe` (Studio, 25 Nov: the tap on
/// "Google Chrome for Testing Helper (Aperitif)", -11 dB; ScreenCaptureKit filtered to the app alone, -12 dB). The tap is
/// the default: it follows helpers that start or restart while the Space runs. ScreenCaptureKit is kept for a Mac where
/// "System Audio Recording" can't be allowed (`defaults write … v5.xAccount.hearing screenCapture`).
enum BotBrowserHearing: String {
    case processTap, screenCapture
    static let settingKey = "v5.xAccount.hearing"
    static var method: BotBrowserHearing {
        UserDefaults.standard.string(forKey: settingKey).flatMap(BotBrowserHearing.init(rawValue:)) ?? .processTap
    }
}
