//
//  WakeWordPolicy.swift
//  ClickyCore
//
//  P7 wake word, the pure decisions around the listener:
//  - WakeWordListenerState: armed / capturing / paused (why) / off (why),
//    from the setting, permissions, on-device support, the mic being busy
//    elsewhere, the screen lock / sleep and push-to-talk / hands-free
//    holding the mic.
//  - EnergyVoiceActivityGate: a cheap level gate so the recognizer only runs
//    while there's sound (it idles in silence).
//  - ProcessCPUUsageWindow: CPU % over the last minute from cumulative CPU
//    time samples (the app reads them with task_info).
//

import Foundation

/// Why the wake word isn't listening right now.
public enum WakeWordInactiveReason: String, Equatable, Sendable, CaseIterable {
    // Off: nothing will change until the owner does something.
    case disabledInSettings
    case onDeviceRecognitionUnsupported
    case microphoneNotAuthorized
    case speechRecognitionNotAuthorized
    case recognizerUnavailable
    case noUsablePhrases
    // Paused: resumes on its own.
    case microphoneInUseByAnotherApp
    /// The default input is a Bluetooth headset: holding its mic open would
    /// switch it to call mode (mono, low-quality audio for whatever is playing).
    case bluetoothMicrophone
    case screenLocked
    case systemAsleep
    case yieldedToPushToTalk
    case yieldedToHandsFree
    case audioEngineFailed

    /// Off reasons stay until settings/permissions change; paused ones clear by themselves.
    public var isPause: Bool {
        switch self {
        case .microphoneInUseByAnotherApp, .bluetoothMicrophone, .screenLocked, .systemAsleep, .yieldedToPushToTalk, .yieldedToHandsFree, .audioEngineFailed:
            return true
        default:
            return false
        }
    }

    /// One short line for the menu and Diagnostics.
    public var displayText: String {
        switch self {
        case .disabledInSettings: return "Off"
        case .onDeviceRecognitionUnsupported: return "Off: on-device speech recognition isn't available for this language"
        case .microphoneNotAuthorized: return "Off: microphone permission is needed"
        case .speechRecognitionNotAuthorized: return "Off: speech recognition permission is needed"
        case .recognizerUnavailable: return "Off: speech recognition isn't available right now"
        case .noUsablePhrases: return "Off: no usable wake phrases (each needs two words, like \"hey theo\")"
        case .microphoneInUseByAnotherApp: return "Paused: another app is using the microphone"
        case .bluetoothMicrophone: return "Paused: the mic is a Bluetooth headset (listening would lower its sound quality)"
        case .screenLocked: return "Paused: screen locked"
        case .systemAsleep: return "Paused: display asleep"
        case .yieldedToPushToTalk: return "Paused for push-to-talk"
        case .yieldedToHandsFree: return "Paused for the hands-free session"
        case .audioEngineFailed: return "Paused: the microphone couldn't start (retrying)"
        }
    }
}

public enum WakeWordListenerState: Equatable, Sendable {
    /// Listening for the wake phrase.
    case armed
    /// The phrase fired; the turn is being heard.
    case capturing
    case paused(WakeWordInactiveReason)
    case off(WakeWordInactiveReason)

    public var displayText: String {
        switch self {
        case .armed: return "Listening for the wake word"
        case .capturing: return "Heard the wake word, listening"
        case .paused(let reason), .off(let reason): return reason.displayText
        }
    }

    public var inactiveReason: WakeWordInactiveReason? {
        switch self {
        case .armed, .capturing: return nil
        case .paused(let reason), .off(let reason): return reason
        }
    }

    /// The microphone should be open.
    public var wantsMicrophone: Bool { self == .armed || self == .capturing }
}

/// What the notch's collapsed pill shows for the wake word.
public enum NotchWakeIndicator: String, Equatable, Sendable {
    case hidden
    /// A small dot: the wake word is armed (or hearing a turn).
    case armed
    /// A red dot: paused (mic in use elsewhere, locked, push-to-talk…).
    case paused

    public static func indicator(for state: WakeWordListenerState) -> NotchWakeIndicator {
        switch state {
        case .armed, .capturing: return .armed
        case .paused: return .paused
        case .off: return .hidden
        }
    }
}

public struct WakeWordConditions: Equatable, Sendable {
    public var isEnabledInSettings: Bool
    public var hasUsablePhrases: Bool
    public var isOnDeviceRecognitionSupported: Bool
    public var isRecognizerAvailable: Bool
    public var isMicrophoneAuthorized: Bool
    public var isSpeechRecognitionAuthorized: Bool
    public var isMicrophoneInUseByAnotherApp: Bool
    public var isDefaultInputBluetooth: Bool
    public var isScreenLocked: Bool
    public var isSystemAsleep: Bool
    public var isPushToTalkCapturing: Bool
    public var isHandsFreeCapturing: Bool
    public var didAudioEngineFail: Bool
    public var isCapturingTurn: Bool

    public init(isEnabledInSettings: Bool = true, hasUsablePhrases: Bool = true, isOnDeviceRecognitionSupported: Bool = true,
                isRecognizerAvailable: Bool = true, isMicrophoneAuthorized: Bool = true, isSpeechRecognitionAuthorized: Bool = true,
                isMicrophoneInUseByAnotherApp: Bool = false, isDefaultInputBluetooth: Bool = false, isScreenLocked: Bool = false, isSystemAsleep: Bool = false,
                isPushToTalkCapturing: Bool = false, isHandsFreeCapturing: Bool = false, didAudioEngineFail: Bool = false,
                isCapturingTurn: Bool = false) {
        self.isEnabledInSettings = isEnabledInSettings
        self.hasUsablePhrases = hasUsablePhrases
        self.isOnDeviceRecognitionSupported = isOnDeviceRecognitionSupported
        self.isRecognizerAvailable = isRecognizerAvailable
        self.isMicrophoneAuthorized = isMicrophoneAuthorized
        self.isSpeechRecognitionAuthorized = isSpeechRecognitionAuthorized
        self.isMicrophoneInUseByAnotherApp = isMicrophoneInUseByAnotherApp
        self.isDefaultInputBluetooth = isDefaultInputBluetooth
        self.isScreenLocked = isScreenLocked
        self.isSystemAsleep = isSystemAsleep
        self.isPushToTalkCapturing = isPushToTalkCapturing
        self.isHandsFreeCapturing = isHandsFreeCapturing
        self.didAudioEngineFail = didAudioEngineFail
        self.isCapturingTurn = isCapturingTurn
    }

    /// Off reasons first (the owner must act), then pauses, most specific first.
    public var state: WakeWordListenerState {
        if !isEnabledInSettings { return .off(.disabledInSettings) }
        if !hasUsablePhrases { return .off(.noUsablePhrases) }
        if !isOnDeviceRecognitionSupported { return .off(.onDeviceRecognitionUnsupported) }
        if !isMicrophoneAuthorized { return .off(.microphoneNotAuthorized) }
        if !isSpeechRecognitionAuthorized { return .off(.speechRecognitionNotAuthorized) }
        if !isRecognizerAvailable { return .off(.recognizerUnavailable) }
        if isPushToTalkCapturing { return .paused(.yieldedToPushToTalk) }
        if isHandsFreeCapturing { return .paused(.yieldedToHandsFree) }
        if isScreenLocked { return .paused(.screenLocked) }
        if isSystemAsleep { return .paused(.systemAsleep) }
        if isMicrophoneInUseByAnotherApp { return .paused(.microphoneInUseByAnotherApp) }
        if isDefaultInputBluetooth { return .paused(.bluetoothMicrophone) }
        if didAudioEngineFail { return .paused(.audioEngineFailed) }
        return isCapturingTurn ? .capturing : .armed
    }
}

// MARK: - Energy gate

/// A level gate in dBFS that adapts to the mic's own noise floor.
///
/// P8: the floor is a low percentile (20th) of the buffer levels over the
/// last 8 s, digital silence left out, so a quiet webcam mic (floor near
/// -75 dBFS, speech across the desk near -55) opens on speech without a
/// fixed -58 dB bar it rarely reached. Opens once the level stays
/// `openMarginDecibels` above the floor for `openHoldSeconds`; closes after
/// `closeHangoverSeconds` back near the floor. Steady noise (a fan, a TV)
/// becomes the floor within the window and stops holding the gate open.
/// The recognizer is fed only while it's open (plus the caller's pre-roll).
public struct EnergyVoiceActivityGate: Sendable {
    public enum Transition: Equatable, Sendable {
        case opened
        case closed
    }

    public var openMarginDecibels: Double = 8
    public var closeMarginDecibels: Double = 4
    /// Never opens below this level, however quiet the room (digital silence, a muted mic).
    public var absoluteOpenFloorDecibels: Double = -72
    public var openHoldSeconds: TimeInterval = 0.06
    public var closeHangoverSeconds: TimeInterval = 1.2
    /// How much recent audio the floor is measured over.
    public var noiseFloorWindowSeconds: TimeInterval = 8
    /// The floor is this percentile of the window's levels.
    public var noiseFloorPercentile: Double = 0.2
    /// Levels below this are digital silence (a muted or starting device), not room noise.
    public static let digitalSilenceDecibels: Double = -100
    static let floorRecomputeSeconds: TimeInterval = 0.25

    public private(set) var noiseFloorDecibels: Double = -100
    public private(set) var isOpen = false
    /// The loudest buffer in the last open stretch (for wakeStatus).
    public private(set) var lastOpenPeakDecibels: Double?
    private var secondsAboveOpenThreshold: TimeInterval = 0
    private var secondsBelowCloseThreshold: TimeInterval = 0
    private var recentLevels: [(levelDecibels: Double, durationSeconds: TimeInterval)] = []
    private var recentLevelsSeconds: TimeInterval = 0
    private var secondsSinceFloorRecompute: TimeInterval = .infinity
    private var currentOpenPeakDecibels: Double = -120

    public init() {}

    public var openThresholdDecibels: Double { max(noiseFloorDecibels + openMarginDecibels, absoluteOpenFloorDecibels) }
    public var closeThresholdDecibels: Double { max(noiseFloorDecibels + closeMarginDecibels, absoluteOpenFloorDecibels - 4) }

    /// One buffer's level. Returns a transition when the gate flips.
    public mutating func process(levelDecibels: Double, durationSeconds: TimeInterval) -> Transition? {
        let levelDecibels = levelDecibels.isFinite ? max(levelDecibels, -120) : -120
        updateNoiseFloor(levelDecibels: levelDecibels, durationSeconds: durationSeconds)

        if isOpen {
            currentOpenPeakDecibels = max(currentOpenPeakDecibels, levelDecibels)
            if levelDecibels < closeThresholdDecibels {
                secondsBelowCloseThreshold += durationSeconds
                if secondsBelowCloseThreshold >= closeHangoverSeconds {
                    isOpen = false
                    secondsAboveOpenThreshold = 0
                    secondsBelowCloseThreshold = 0
                    lastOpenPeakDecibels = currentOpenPeakDecibels
                    return .closed
                }
            } else {
                secondsBelowCloseThreshold = 0
            }
            return nil
        }

        if levelDecibels >= openThresholdDecibels {
            secondsAboveOpenThreshold += durationSeconds
            if secondsAboveOpenThreshold >= openHoldSeconds {
                isOpen = true
                secondsBelowCloseThreshold = 0
                currentOpenPeakDecibels = levelDecibels
                return .opened
            }
        } else {
            secondsAboveOpenThreshold = 0
        }
        return nil
    }

    private mutating func updateNoiseFloor(levelDecibels: Double, durationSeconds: TimeInterval) {
        if levelDecibels > Self.digitalSilenceDecibels {
            recentLevels.append((levelDecibels, durationSeconds))
            recentLevelsSeconds += durationSeconds
            while recentLevelsSeconds > noiseFloorWindowSeconds, recentLevels.count > 1 {
                recentLevelsSeconds -= recentLevels.removeFirst().durationSeconds
            }
        }
        secondsSinceFloorRecompute += durationSeconds
        guard secondsSinceFloorRecompute >= Self.floorRecomputeSeconds else { return }
        secondsSinceFloorRecompute = 0
        noiseFloorDecibels = Self.percentileLevel(recentLevels.map(\.levelDecibels), percentile: noiseFloorPercentile) ?? -100
    }

    /// The level at `percentile` (0…1) of `levels`; nil when empty.
    public static func percentileLevel(_ levels: [Double], percentile: Double) -> Double? {
        guard !levels.isEmpty else { return nil }
        let sortedLevels = levels.sorted()
        let index = Int((Double(sortedLevels.count - 1) * min(1, max(0, percentile))).rounded(.down))
        return sortedLevels[index]
    }

    /// RMS level of float samples in dBFS (-120 for silence).
    public static func rmsDecibels(samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sumOfSquares: Double = 0
        for sample in samples { sumOfSquares += Double(sample) * Double(sample) }
        let rms = (sumOfSquares / Double(samples.count)).squareRoot()
        return rms > 0 ? max(-120, 20 * log10(rms)) : -120
    }
}

// MARK: - CPU over the last minute

/// Cumulative CPU seconds sampled against wall-clock seconds; the percent is
/// the slope over the samples in the window (100 = one core busy).
public struct ProcessCPUUsageWindow: Sendable {
    public static let windowSeconds: TimeInterval = 60

    private var samples: [(wallSeconds: TimeInterval, cpuSeconds: TimeInterval)] = []

    public init() {}

    public mutating func record(wallSeconds: TimeInterval, cpuSeconds: TimeInterval) {
        samples.append((wallSeconds, cpuSeconds))
        // Keep one sample older than the window so the span covers it fully.
        while samples.count > 2, let secondSample = samples.dropFirst().first, wallSeconds - secondSample.wallSeconds >= Self.windowSeconds {
            samples.removeFirst()
        }
    }

    /// Nil until two samples at least a second apart exist.
    public var percent: Double? {
        guard let firstSample = samples.first, let lastSample = samples.last else { return nil }
        let wallSpan = lastSample.wallSeconds - firstSample.wallSeconds
        guard wallSpan >= 1 else { return nil }
        return max(0, (lastSample.cpuSeconds - firstSample.cpuSeconds) / wallSpan * 100)
    }

    public var spanSeconds: TimeInterval {
        guard let firstSample = samples.first, let lastSample = samples.last else { return 0 }
        return lastSample.wallSeconds - firstSample.wallSeconds
    }
}
