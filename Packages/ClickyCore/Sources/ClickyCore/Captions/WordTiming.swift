//
//  WordTiming.swift
//  ClickyCore
//
//  When each word of a Qwen segment is spoken, estimated from its audio
//  (Qwen gives no word timestamps):
//   1. the exact WAV duration, minus leading/trailing silence (−45 dBFS in
//      10 ms windows);
//   2. words spread over [lead, duration − tail] by syllables (acronyms per
//      letter, numbers spelled out, CJK per character) plus pause weights
//      after punctuation (. ! ? … newline = 2, , ; : — – = 1);
//   3. each pause (a silence ≥ 120 ms) pulls the nearest word start within
//      ±250 ms onto its midpoint, and the words between are re-spread.
//  Runaway audio (over 3x the chars/15 s estimate) is cut at its last
//  pause before that limit (overrunCutTime).
//

import Foundation

public struct PCMAudio: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { Double(samples.count) / sampleRate }

    /// The first `seconds` of the audio.
    public func prefix(seconds: TimeInterval) -> PCMAudio {
        PCMAudio(samples: Array(samples.prefix(max(0, Int(seconds * sampleRate)))), sampleRate: sampleRate)
    }

    /// Mono PCM from a RIFF/WAVE file: 16-bit integer or 32-bit float,
    /// any channel count (channels are averaged).
    public init?(wavData: Data) {
        let bytes = [UInt8](wavData)
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45] else { return nil }
        func uint32(_ offset: Int) -> UInt32 { UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24 }
        func uint16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        var offset = 12
        var formatTag: UInt16 = 0, channelCount: UInt16 = 0, bitsPerSample: UInt16 = 0, rate: UInt32 = 0
        var dataRange: Range<Int>?
        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii) ?? ""
            let chunkSize = Int(uint32(offset + 4))
            let chunkStart = offset + 8
            if chunkID == "fmt ", chunkStart + 16 <= bytes.count {
                formatTag = uint16(chunkStart)
                channelCount = uint16(chunkStart + 2)
                rate = uint32(chunkStart + 4)
                bitsPerSample = uint16(chunkStart + 14)
                if formatTag == 0xFFFE, chunkStart + 26 <= bytes.count { formatTag = uint16(chunkStart + 24) } // WAVE_FORMAT_EXTENSIBLE
            } else if chunkID == "data" {
                // Streaming writers sometimes leave the size at 0 or 0xFFFFFFFF.
                let end = chunkSize == 0 || chunkStart + chunkSize > bytes.count ? bytes.count : chunkStart + chunkSize
                dataRange = chunkStart..<end
                break
            }
            offset = chunkStart + chunkSize + (chunkSize & 1)
        }
        guard let dataRange, channelCount > 0, rate > 0 else { return nil }
        let channels = Int(channelCount)
        var monoSamples: [Float] = []
        if formatTag == 1 && bitsPerSample == 16 {
            let frameBytes = 2 * channels
            monoSamples.reserveCapacity(dataRange.count / frameBytes)
            var frameStart = dataRange.lowerBound
            while frameStart + frameBytes <= dataRange.upperBound {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += Float(Int16(bitPattern: uint16(frameStart + 2 * channel))) / 32768
                }
                monoSamples.append(sum / Float(channels))
                frameStart += frameBytes
            }
        } else if formatTag == 3 && bitsPerSample == 32 {
            let frameBytes = 4 * channels
            monoSamples.reserveCapacity(dataRange.count / frameBytes)
            var frameStart = dataRange.lowerBound
            while frameStart + frameBytes <= dataRange.upperBound {
                var sum: Float = 0
                for channel in 0..<channels { sum += Float(bitPattern: uint32(frameStart + 4 * channel)) }
                monoSamples.append(sum / Float(channels))
                frameStart += frameBytes
            }
        } else {
            return nil
        }
        self.init(samples: monoSamples, sampleRate: Double(rate))
    }
}

public struct WordTimes: Equatable, Sendable {
    /// Start time of each word (seconds from the start of the audio).
    public let starts: [TimeInterval]
    public let ends: [TimeInterval]
    public let lead: TimeInterval
    public let tail: TimeInterval
    public let duration: TimeInterval

    /// Spoken characters at time `t`: through the end of every word that has started.
    public func spokenCharacters(at time: TimeInterval, wordRanges: [Range<Int>], totalCharacters: Int) -> Int {
        guard time < duration - tail || duration == 0 else { return totalCharacters }
        var spoken = 0
        for (wordIndex, start) in starts.enumerated() where start <= time && wordIndex < wordRanges.count {
            spoken = wordRanges[wordIndex].upperBound
        }
        return spoken
    }
}

public enum WordTiming {
    public static let silenceThresholdDBFS: Float = -45
    public static let windowSeconds: TimeInterval = 0.010
    public static let minimumPauseSeconds: TimeInterval = 0.120
    public static let snapRadiusSeconds: TimeInterval = 0.250

    /// Leading and trailing silence, in seconds (10 ms windows below −45 dBFS).
    public static func silenceBounds(_ audio: PCMAudio) -> (lead: TimeInterval, tail: TimeInterval) {
        let loudWindows = windowLoudness(audio)
        guard let firstLoud = loudWindows.firstIndex(of: true), let lastLoud = loudWindows.lastIndex(of: true) else {
            return (audio.duration, 0)
        }
        let lead = Double(firstLoud) * windowSeconds
        let tail = max(0, audio.duration - Double(lastLoud + 1) * windowSeconds)
        return (lead, tail)
    }

    /// Silences of at least 120 ms strictly inside the speech, as (start, end).
    public static func pauses(_ audio: PCMAudio) -> [(start: TimeInterval, end: TimeInterval)] {
        let loudWindows = windowLoudness(audio)
        guard let firstLoud = loudWindows.firstIndex(of: true), let lastLoud = loudWindows.lastIndex(of: true) else { return [] }
        var pauses: [(TimeInterval, TimeInterval)] = []
        var quietStart: Int?
        for windowIndex in firstLoud...lastLoud {
            if !loudWindows[windowIndex] {
                if quietStart == nil { quietStart = windowIndex }
            } else if let start = quietStart {
                let lengthSeconds = Double(windowIndex - start) * windowSeconds
                if lengthSeconds >= minimumPauseSeconds { pauses.append((Double(start) * windowSeconds, Double(windowIndex) * windowSeconds)) }
                quietStart = nil
            }
        }
        return pauses
    }

    /// Runaway audio (longer than 3x chars/15 s): where to cut it, at the
    /// start of the last pause before that limit (else at the limit).
    /// nil when the audio is a normal length.
    public static func overrunCutTime(_ audio: PCMAudio, characters: Int) -> TimeInterval? {
        // At least 3 s: a short segment ("hey! ") plus the voice's lead-in silence ran past a 1 s limit.
        let limit = max(3, QwenTuning.overrunFactor * QwenTuning.estimatedAudioSeconds(characters: characters))
        guard limit > 0, audio.duration > limit else { return nil }
        let lastPauseBeforeLimit = pauses(audio).last { $0.start < limit }
        return lastPauseBeforeLimit?.start ?? limit
    }

    private static func windowLoudness(_ audio: PCMAudio) -> [Bool] {
        let windowLength = max(1, Int(audio.sampleRate * windowSeconds))
        let threshold = pow(10, silenceThresholdDBFS / 20)
        var loudness: [Bool] = []
        var windowStart = 0
        while windowStart < audio.samples.count {
            let windowEnd = min(audio.samples.count, windowStart + windowLength)
            var sumOfSquares: Float = 0
            for sampleIndex in windowStart..<windowEnd { sumOfSquares += audio.samples[sampleIndex] * audio.samples[sampleIndex] }
            let rms = sqrt(sumOfSquares / Float(windowEnd - windowStart))
            loudness.append(rms >= threshold)
            windowStart = windowEnd
        }
        return loudness
    }

    // MARK: Syllables

    private static let spellOutFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "en_US")
        return formatter
    }()

    /// Rough syllables: vowel groups; acronyms per letter; numbers spelled
    /// out; CJK per character. At least 1.
    public static func syllables(in word: String) -> Int {
        let letters = word.filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty else { return 1 }
        if letters.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }) {
            return letters.count
        }
        if letters.allSatisfy(\.isNumber), let number = Double(letters), let spelled = spellOutFormatter.string(from: NSNumber(value: number)) {
            return spelled.split(whereSeparator: { $0 == " " || $0 == "-" }).reduce(0) { $0 + syllables(in: String($1)) }
        }
        if letters.count >= 2, letters.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            return letters.count // "PR", "URL", "API"
        }
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var count = 0
        var previousWasVowel = false
        for character in letters.lowercased() {
            let isVowel = vowels.contains(character)
            if isVowel && !previousWasVowel { count += 1 }
            previousWasVowel = isVowel
        }
        if letters.lowercased().hasSuffix("e") && count > 1 && !letters.lowercased().hasSuffix("le") { count -= 1 }
        return max(1, count)
    }

    /// Pause after a word, from the punctuation that follows it.
    public static func pauseWeight(after trailingText: Substring) -> Double {
        if trailingText.contains(where: { ".!?…\n".contains($0) }) { return 2 }
        if trailingText.contains(where: { ",;:—–".contains($0) }) { return 1 }
        return 0
    }

    // MARK: Spreading

    /// Word start/end times for `speech` (word ranges in Characters) spoken in `audio`.
    public static func wordTimes(speech: String, wordRanges: [Range<Int>], audio: PCMAudio) -> WordTimes {
        let (lead, tail) = silenceBounds(audio)
        let duration = audio.duration
        let spanStart = min(lead, duration)
        let spanEnd = max(spanStart, duration - tail)
        guard !wordRanges.isEmpty else {
            return WordTimes(starts: [], ends: [], lead: lead, tail: tail, duration: duration)
        }

        let characters = Array(speech)
        var syllableWeights: [Double] = []
        var pauseWeights: [Double] = []
        for (wordIndex, wordRange) in wordRanges.enumerated() {
            syllableWeights.append(Double(syllables(in: String(characters[wordRange]))))
            let gapEnd = wordIndex + 1 < wordRanges.count ? wordRanges[wordIndex + 1].lowerBound : characters.count
            let gap = String(characters[wordRange.upperBound..<max(wordRange.upperBound, gapEnd)])
            // The last word's trailing pause is the audio tail, already excluded.
            pauseWeights.append(wordIndex + 1 < wordRanges.count ? pauseWeight(after: Substring(gap)) : 0)
        }
        let totalWeight = syllableWeights.reduce(0, +) + pauseWeights.reduce(0, +)
        let unit = totalWeight > 0 ? (spanEnd - spanStart) / totalWeight : 0

        var starts: [TimeInterval] = []
        var ends: [TimeInterval] = []
        var cursor = spanStart
        for wordIndex in wordRanges.indices {
            starts.append(cursor)
            cursor += syllableWeights[wordIndex] * unit
            ends.append(cursor)
            cursor += pauseWeights[wordIndex] * unit
        }

        // Snap word starts to pause midpoints, then re-spread between anchors.
        var anchoredStarts: [Int: TimeInterval] = [0: starts[0]]
        for pause in pauses(audio) {
            let midpoint = (pause.start + pause.end) / 2
            let candidates = starts.indices.dropFirst().filter { abs(starts[$0] - midpoint) <= snapRadiusSeconds && anchoredStarts[$0] == nil }
            guard let nearest = candidates.min(by: { abs(starts[$0] - midpoint) < abs(starts[$1] - midpoint) }) else { continue }
            anchoredStarts[nearest] = midpoint
        }
        let anchorIndexes = anchoredStarts.keys.sorted()
        // Keep anchors monotonic: drop any that would go backwards.
        var monotonicAnchors: [(index: Int, time: TimeInterval)] = []
        for anchorIndex in anchorIndexes {
            let time = anchoredStarts[anchorIndex]!
            if let last = monotonicAnchors.last, time <= last.time { continue }
            monotonicAnchors.append((anchorIndex, time))
        }
        var snappedStarts = starts
        var snappedEnds = ends
        for (anchorPosition, anchor) in monotonicAnchors.enumerated() {
            let nextAnchor = anchorPosition + 1 < monotonicAnchors.count ? monotonicAnchors[anchorPosition + 1] : nil
            let sectionEndIndex = nextAnchor?.index ?? wordRanges.count
            let sectionEndTime = nextAnchor?.time ?? spanEnd
            let originalStart = starts[anchor.index]
            let originalEnd = nextAnchor.map { starts[$0.index] } ?? spanEnd
            let scale = originalEnd > originalStart ? (sectionEndTime - anchor.time) / (originalEnd - originalStart) : 0
            for wordIndex in anchor.index..<sectionEndIndex {
                snappedStarts[wordIndex] = anchor.time + (starts[wordIndex] - originalStart) * scale
                snappedEnds[wordIndex] = anchor.time + (ends[wordIndex] - originalStart) * scale
            }
        }
        return WordTimes(starts: snappedStarts, ends: snappedEnds, lead: lead, tail: tail, duration: duration)
    }
}
