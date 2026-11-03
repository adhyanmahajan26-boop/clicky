//
//  AudioEngineHub.swift
//  leanring-buddy
//
//  P6.4 "aec" echo mode: ONE AVAudioEngine shared by the hands-free mic and
//  both voices. macOS voice processing cancels only what plays through its
//  own IO unit, so Clicky's voice has to come out of the mic's engine for
//  the canceller to see the reference signal.
//
//  - startVoiceProcessingCapture: engine.stop() → voice processing on →
//    other-audio ducking off (.min) → re-read the input format → install
//    the recognition tap → start. Any throw is the caller's cue to fall
//    back (EchoCancellationPolicy: → halfDuplex).
//  - Each voice gets a SharedEnginePlayerChannel (player node → time pitch
//    → main mixer). The time pitch is bypassed at rate 1.
//  - The hub is only live while hands-free listens with AEC on; otherwise
//    the voices use their usual paths (AVAudioPlayer / AVSpeechSynthesizer).
//  - AudioOutputRouteInspector: is the default output headphones? (then no
//    AEC is needed; the mode stays open).
//  - P7: the microphone claims. Push-to-talk and hands-free claim the mic
//    while they capture; the wake-word listener watches the claims, stops
//    its own engine while any is held (so it never fights voice processing
//    or the dictation engine) and resumes after the last one is released.
//

import AVFoundation
import ClickyCore
import CoreAudio
import Foundation

extension AVAudioInputNode {
    /// False when there's no real mic (none plugged in, or one that just went away). A tap then raises an
    /// Objective-C exception. AppKit catches it on the main thread, but it leaves Swift's executor tracking
    /// pointing at a dead stack frame, so the app crashes seconds later in whichever timer checks it next.
    var hasUsableMicFormat: Bool {
        let hardware = inputFormat(forBus: 0)
        let output = outputFormat(forBus: 0)
        return hardware.sampleRate > 0 && hardware.channelCount > 0 && output.sampleRate > 0 && output.channelCount > 0
    }
}

/// Who is capturing from the mic for a turn (the wake listener yields to them).
enum ExclusiveMicrophoneUser: String {
    case pushToTalk
    case handsFree
    case dictation
    case call
}

@MainActor
final class AudioEngineHub {
    let audioEngine = AVAudioEngine()

    /// P7: mic claims by push-to-talk / hands-free (see the header).
    private(set) var exclusiveMicrophoneUsers: Set<ExclusiveMicrophoneUser> = []
    /// Called on every change of `exclusiveMicrophoneUsers`.
    var onExclusiveMicrophoneUsersChanged: ((Set<ExclusiveMicrophoneUser>) -> Void)?

    func claimMicrophone(for microphoneUser: ExclusiveMicrophoneUser) {
        guard !exclusiveMicrophoneUsers.contains(microphoneUser) else { return }
        exclusiveMicrophoneUsers.insert(microphoneUser)
        onExclusiveMicrophoneUsersChanged?(exclusiveMicrophoneUsers)
    }

    func releaseMicrophone(for microphoneUser: ExclusiveMicrophoneUser) {
        guard exclusiveMicrophoneUsers.contains(microphoneUser) else { return }
        exclusiveMicrophoneUsers.remove(microphoneUser)
        onExclusiveMicrophoneUsersChanged?(exclusiveMicrophoneUsers)
    }
    /// Voice processing is on and the shared engine is running (mic + voices).
    private(set) var isVoiceProcessingActive = false
    private var playerChannels: [SharedEnginePlayerChannel] = []
    private var configurationChangeObserver: NSObjectProtocol?

    /// A player for one voice. Attached right away if the engine is live.
    func makePlayerChannel() -> SharedEnginePlayerChannel {
        let playerChannel = SharedEnginePlayerChannel()
        playerChannels.append(playerChannel)
        if isVoiceProcessingActive { attachAndConnect(playerChannel) }
        return playerChannel
    }

    /// Turns voice processing on and starts the shared engine with the
    /// recognition tap. Returns the mic format the tap delivers.
    func startVoiceProcessingCapture(tapBlock: @escaping AVAudioNodeTapBlock) throws -> AVAudioFormat {
        guard !isVoiceProcessingActive else { return audioEngine.inputNode.outputFormat(forBus: 0) }
        audioEngine.stop()
        let inputNode = audioEngine.inputNode
        try inputNode.setVoiceProcessingEnabled(true)
        do {
            // Voice processing ducks other audio by default (music would go quiet).
            inputNode.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false,
                duckingLevel: .min
            )
            // The output side is the voice-processing unit now: wire the mixer to it.
            let outputFormat = audioEngine.outputNode.inputFormat(forBus: 0)
            if outputFormat.sampleRate > 0 && outputFormat.channelCount > 0 {
                audioEngine.connect(audioEngine.mainMixerNode, to: audioEngine.outputNode, format: outputFormat)
            }
            for playerChannel in playerChannels { attachAndConnect(playerChannel) }
            // Re-read: voice processing changes the mic format.
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw HandsFreeListeningSessionError(message: "Voice processing gave no usable mic format.")
            }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: tapBlock)
            audioEngine.prepare()
            try audioEngine.start()
            isVoiceProcessingActive = true
            observeConfigurationChanges()
            print("🎙️ AEC: shared engine on, mic \(inputFormat.sampleRate)Hz × \(inputFormat.channelCount)")
            return inputFormat
        } catch {
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
            try? inputNode.setVoiceProcessingEnabled(false)
            throw error
        }
    }

    /// Stops the mic and the voices on the shared engine (a voice that was
    /// playing ends its segment), and turns voice processing off.
    func stopVoiceProcessingCapture() {
        guard isVoiceProcessingActive else { return }
        isVoiceProcessingActive = false
        if let configurationChangeObserver { NotificationCenter.default.removeObserver(configurationChangeObserver) }
        configurationChangeObserver = nil
        for playerChannel in playerChannels { playerChannel.sharedEngineWillStop() }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? audioEngine.inputNode.setVoiceProcessingEnabled(false)
        print("🎙️ AEC: shared engine off")
    }

    private func attachAndConnect(_ playerChannel: SharedEnginePlayerChannel) {
        if playerChannel.playerNode.engine == nil { audioEngine.attach(playerChannel.playerNode) }
        if playerChannel.timePitchUnit.engine == nil { audioEngine.attach(playerChannel.timePitchUnit) }
        let playbackFormat = SharedEnginePlayerChannel.playbackFormat
        audioEngine.connect(playerChannel.playerNode, to: playerChannel.timePitchUnit, format: playbackFormat)
        audioEngine.connect(playerChannel.timePitchUnit, to: audioEngine.mainMixerNode, format: playbackFormat)
    }

    /// A device change stops the engine: end what's playing and start again.
    private func observeConfigurationChanges() {
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAfterConfigurationChange() }
        }
    }

    private func restartAfterConfigurationChange() {
        guard isVoiceProcessingActive else { return }
        for playerChannel in playerChannels { playerChannel.sharedEngineWillStop() }
        do {
            audioEngine.prepare()
            try audioEngine.start()
            print("🎙️ AEC: audio configuration changed, shared engine restarted")
        } catch {
            print("⚠️ AEC: audio configuration changed and the shared engine didn't restart: \(error)")
        }
    }
}

/// One voice's player on the shared engine: buffers are converted to one
/// fixed format, the clock is the player's own sample time (media time,
/// so it stays on the words at any rate).
@MainActor
final class SharedEnginePlayerChannel {
    static let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    let playerNode = AVAudioPlayerNode()
    let timePitchUnit = AVAudioUnitTimePitch()
    /// The hub stopped (hands-free ended, device change): the voice ends its segment.
    var onSharedEngineStopped: (() -> Void)?

    private var shouldStartOnNextBuffer = false
    private var sampleRateConverter: AVAudioConverter?

    var isEngineRunning: Bool { playerNode.engine?.isRunning == true }
    /// Never attached (hands-free hasn't run with AEC yet): nothing to stop.
    private var isAttached: Bool { playerNode.engine != nil }

    /// A new segment: the player's clock restarts at 0 with its first buffer.
    func startSegment(rate: Double) {
        if isAttached { playerNode.stop() }
        timePitchUnit.rate = Float(rate)
        // Time pitch only when the rate isn't 1.
        timePitchUnit.bypass = abs(rate - 1) < 0.001
        sampleRateConverter?.reset()
        shouldStartOnNextBuffer = true
    }

    /// Schedules `sourceBuffer` after anything already scheduled; false if
    /// the engine isn't running or the audio can't be converted.
    func schedule(_ sourceBuffer: AVAudioPCMBuffer, onPlayedBack: @escaping @MainActor () -> Void) -> Bool {
        guard isEngineRunning, let playbackBuffer = convertedToPlaybackFormat(sourceBuffer) else { return false }
        playerNode.scheduleBuffer(playbackBuffer, completionCallbackType: .dataPlayedBack,
                                  completionHandler: Self.makeCompletionHandler(onPlayedBack: onPlayedBack))
        if shouldStartOnNextBuffer {
            shouldStartOnNextBuffer = false
            playerNode.volume = CompanionSpeechOutput.isZeroVolumeForTests ? 0 : 1
            playerNode.play()
        }
        return true
    }

    /// Samples played since the segment's first buffer, in playbackFormat.
    var playedSampleTime: Int64 {
        guard isEngineRunning, let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return max(0, playerTime.sampleTime)
    }

    var playedSeconds: TimeInterval { Double(playedSampleTime) / Self.playbackFormat.sampleRate }

    func pause() {
        guard isEngineRunning else { return }
        playerNode.pause()
    }

    func resume() {
        guard isEngineRunning, !shouldStartOnNextBuffer else { return }
        playerNode.play()
    }

    func stop() {
        shouldStartOnNextBuffer = false
        if isAttached { playerNode.stop() }
    }

    func sharedEngineWillStop() {
        stop()
        onSharedEngineStopped?()
    }

    private func convertedToPlaybackFormat(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let playbackFormat = Self.playbackFormat
        if sourceBuffer.format == playbackFormat { return sourceBuffer }
        if sampleRateConverter?.inputFormat != sourceBuffer.format {
            sampleRateConverter = AVAudioConverter(from: sourceBuffer.format, to: playbackFormat)
        }
        guard let sampleRateConverter else { return nil }
        let outputCapacity = AVAudioFrameCount(
            (Double(sourceBuffer.frameLength) * playbackFormat.sampleRate / sourceBuffer.format.sampleRate).rounded(.up)
        ) + 1024
        guard let playbackBuffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: outputCapacity) else { return nil }
        let inputState = ConverterInputState(sourceBuffer: sourceBuffer)
        var conversionError: NSError?
        // .noDataNow keeps the converter's state between a segment's buffers.
        let conversionStatus = sampleRateConverter.convert(to: playbackBuffer, error: &conversionError,
                                                           withInputFrom: Self.makeConverterInputBlock(inputState: inputState))
        if conversionStatus == .error {
            print("⚠️ AEC: couldn't convert voice audio: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        return playbackBuffer
    }

    // MARK: - Off-main-thread callbacks

    /// Built nonisolated: AVAudioPlayerNode calls it on its own thread.
    private nonisolated static func makeCompletionHandler(onPlayedBack: @escaping @MainActor () -> Void) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        let playedBackBox = MainActorCallbackBox(callback: onPlayedBack)
        return { @Sendable _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { playedBackBox.callback() } }
        }
    }

    private nonisolated static func makeConverterInputBlock(inputState: ConverterInputState) -> AVAudioConverterInputBlock {
        return { _, inputStatus in
            guard let sourceBuffer = inputState.takeSourceBuffer() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
    }
}

/// Hands one buffer to AVAudioConverter exactly once (it runs synchronously
/// inside convert, but the block type is escaping).
private nonisolated final class ConverterInputState: @unchecked Sendable {
    private var sourceBuffer: AVAudioPCMBuffer?

    init(sourceBuffer: AVAudioPCMBuffer) {
        self.sourceBuffer = sourceBuffer
    }

    func takeSourceBuffer() -> AVAudioPCMBuffer? {
        defer { sourceBuffer = nil }
        return sourceBuffer
    }
}

/// Carries a main-actor callback through an audio-thread closure.
private nonisolated struct MainActorCallbackBox: @unchecked Sendable {
    let callback: @MainActor () -> Void
}

/// Reads the default output device's transport type and data source from
/// CoreAudio; AudioOutputRouteClassifier decides whether that's headphones.
enum AudioOutputRouteInspector {
    static func isDefaultOutputHeadphones() -> Bool {
        guard let outputDeviceID = defaultOutputDeviceID() else { return false }
        let transportType = uint32Property(of: outputDeviceID, selector: kAudioDevicePropertyTransportType, scope: kAudioObjectPropertyScopeGlobal)
        let dataSource = uint32Property(of: outputDeviceID, selector: kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        let isHeadphones = AudioOutputRouteClassifier.isHeadphoneRoute(transportType: transportType, dataSource: dataSource)
        print("🎧 AEC: output transport \(fourCharacterText(transportType)), source \(fourCharacterText(dataSource)) → \(isHeadphones ? "headphones" : "speakers")")
        return isHeadphones
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var outputDeviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &propertySize, &outputDeviceID)
        return status == noErr && outputDeviceID != 0 ? outputDeviceID : nil
    }

    private static func uint32Property(of deviceID: AudioDeviceID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> UInt32? {
        var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(deviceID, &propertyAddress) else { return nil }
        var propertyValue: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, &propertyValue)
        return status == noErr ? propertyValue : nil
    }

    private static func fourCharacterText(_ code: UInt32?) -> String {
        guard let code else { return "none" }
        let characterBytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(bytes: characterBytes, encoding: .ascii) ?? String(code)
    }
}
