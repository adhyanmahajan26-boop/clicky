//
//  EchoCancellation.swift
//  ClickyCore
//
//  The pure half of v2.voice.echoMode "aec" (P6.4): the app plays both
//  voices through the mic's own AVAudioEngine so the voice processor has
//  the reference signal and can cancel Clicky's voice. Everything here is
//  device-free so it can be unit-tested:
//
//   - EchoCancellationPolicy: which mode actually runs. Headphones need no
//     cancellation (stay "open"); a throw while turning voice processing on
//     falls back to "halfDuplex".
//   - AudioOutputRouteClassifier: headphones from CoreAudio's transport
//     type / data source codes (Bluetooth, BLE, 'hdpn').
//   - SpeechWordMarkerTimeline: AVSpeechSynthesizer word markers
//     (byteSampleOffset + text range) → characters spoken at a sample.
//   - EchoGuard additions: the 60 % partial-overlap echo filter and the
//     command phrases accepted while Clicky is playing.
//

import Foundation

// MARK: - Mode decision

public enum EchoCancellationPolicy {
    /// Voice processing is worth turning on: "aec" asked for and the sound
    /// goes to speakers (headphones can't leak into the mic).
    public static func shouldEnableVoiceProcessing(requestedMode: ClickySettings.EchoMode, isHeadphoneRoute: Bool) -> Bool {
        requestedMode == .aec && !isHeadphoneRoute
    }

    /// The mode that actually runs. `enableVoiceProcessing` is only called
    /// when it's needed; if it throws, the mic falls back to half-duplex
    /// (nothing heard while Clicky talks counts) and the error is logged.
    public static func resolvedMode(requestedMode: ClickySettings.EchoMode,
                                    isHeadphoneRoute: Bool,
                                    enableVoiceProcessing: () throws -> Void,
                                    log: (String) -> Void) -> ClickySettings.EchoMode {
        guard requestedMode == .aec else { return requestedMode }
        guard shouldEnableVoiceProcessing(requestedMode: requestedMode, isHeadphoneRoute: isHeadphoneRoute) else {
            log("aec: headphones, echo cancellation not needed (open)")
            return .open
        }
        do {
            try enableVoiceProcessing()
            return .aec
        } catch {
            log("aec: voice processing failed, falling back to halfDuplex: \(error)")
            return .halfDuplex
        }
    }
}

// MARK: - Output route

public enum AudioOutputRouteClassifier {
    /// CoreAudio four-character codes, as UInt32 (big-endian ASCII).
    public static func fourCharacterCode(_ code: String) -> UInt32 {
        code.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// kAudioDeviceTransportTypeBluetooth / ...BluetoothLE.
    public static let bluetoothTransportType = fourCharacterCode("blue")
    public static let bluetoothLowEnergyTransportType = fourCharacterCode("blea")
    /// The headphone data source ('hdpn') of a built-in or USB output.
    public static let headphonesCode = fourCharacterCode("hdpn")

    /// Headphones: Bluetooth / BLE output, or a device whose transport or
    /// current data source is headphones. Anything unknown counts as
    /// speakers (echo cancellation stays on: the safe side).
    public static func isHeadphoneRoute(transportType: UInt32?, dataSource: UInt32?) -> Bool {
        if let transportType,
           transportType == bluetoothTransportType || transportType == bluetoothLowEnergyTransportType || transportType == headphonesCode {
            return true
        }
        return dataSource == headphonesCode
    }
}

// MARK: - Apple word markers

/// Word markers of one utterance written through AVSpeechSynthesizer
/// (`write(_:toBufferCallback:toMarkerCallback:)`), turned into exact
/// caption progress for the samples the player has played.
public struct SpeechWordMarkerTimeline: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        /// Where the word starts, in frames of the synthesizer's buffers.
        public let sourceSampleOffset: Int
        /// UTF-16 end of the word in the utterance's speech string.
        public let utf16End: Int
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// `byteSampleOffset` is in bytes of the synthesizer's buffer format:
    /// frames = bytes / bytesPerFrame (one channel's frame for deinterleaved formats).
    public static func sampleOffset(byteSampleOffset: Int, bytesPerFrame: Int) -> Int {
        max(0, byteSampleOffset) / max(1, bytesPerFrame)
    }

    /// A played position in the player's format → frames of the source buffers.
    public static func sourceSample(playbackSample: Int64, playbackSampleRate: Double, sourceSampleRate: Double) -> Int {
        guard playbackSampleRate > 0, sourceSampleRate > 0, playbackSample > 0 else { return 0 }
        return Int((Double(playbackSample) * sourceSampleRate / playbackSampleRate).rounded(.down))
    }

    /// Adds word markers (they may arrive in several callbacks, in any order).
    public mutating func addWordMarker(byteSampleOffset: Int, bytesPerFrame: Int, utf16Location: Int, utf16Length: Int) {
        let entry = Entry(sourceSampleOffset: Self.sampleOffset(byteSampleOffset: byteSampleOffset, bytesPerFrame: bytesPerFrame),
                          utf16End: max(0, utf16Location) + max(0, utf16Length))
        let insertionIndex = entries.firstIndex { $0.sourceSampleOffset > entry.sourceSampleOffset } ?? entries.count
        entries.insert(entry, at: insertionIndex)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// UTF-16 offset spoken once `sourceSample` frames have played: like
    /// willSpeakRange, a word counts as spoken from its first sample.
    public func spokenUTF16(atSourceSample sourceSample: Int) -> Int {
        var spoken = 0
        for entry in entries where entry.sourceSampleOffset <= sourceSample {
            spoken = max(spoken, entry.utf16End)
        }
        return spoken
    }

    /// Characters of `segment.speech` spoken at `sourceSample`.
    public func spokenCharacters(atSourceSample sourceSample: Int, segment: CaptionSegment) -> Int {
        segment.spokenCharacters(throughUTF16: spokenUTF16(atSourceSample: sourceSample))
    }
}

// MARK: - Echo filter

public extension EchoGuard {
    /// Partial transcripts are judged on their last words only.
    static let echoTrailingWordCount = 4
    /// That share of them heard in Clicky's recent words = the mic heard Clicky.
    static let echoOverlapThreshold = 0.6
    /// The only things that count while Clicky plays in "aec" mode.
    static let commandPhrasesWhilePlaying: [[String]] = [["stop"], ["wait"], ["clicky", "stop"]]

    /// Words of `text` in order, lowercased, letters only.
    static func orderedWords(in text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// Share (0…1) of the last `trailingWordCount` heard words that are in `spokenWords`.
    static func trailingOverlapFraction(heardText: String, spokenWords: Set<String>, trailingWordCount: Int = echoTrailingWordCount) -> Double {
        let trailingWords = orderedWords(in: heardText).suffix(max(1, trailingWordCount))
        guard !trailingWords.isEmpty else { return 0 }
        let containedCount = trailingWords.filter { spokenWords.contains($0) }.count
        return Double(containedCount) / Double(trailingWords.count)
    }

    /// The pure echo rule: the heard words' tail is ≥ 60 % Clicky's words.
    static func isEcho(heardText: String, spokenWords: Set<String>) -> Bool {
        guard !spokenWords.isEmpty else { return false }
        return trailingOverlapFraction(heardText: heardText, spokenWords: spokenWords) >= echoOverlapThreshold
    }

    /// Whether `heardText` is most likely Clicky's own voice at `date`
    /// (judged against what it said in the last 4 seconds).
    func isLikelyEcho(_ heardText: String, at date: Date) -> Bool {
        Self.isEcho(heardText: heardText, spokenWords: recentSpokenWords(at: date))
    }

    /// While Clicky plays, only "stop", "wait" or "clicky stop" (the whole
    /// partial) count, and only if Clicky didn't just say that word itself.
    func acceptsWhilePlaying(_ heardText: String, at date: Date) -> Bool {
        let heardWords = Self.orderedWords(in: heardText)
        guard Self.commandPhrasesWhilePlaying.contains(heardWords) else { return false }
        return accepts(heardText, at: date)
    }
}
