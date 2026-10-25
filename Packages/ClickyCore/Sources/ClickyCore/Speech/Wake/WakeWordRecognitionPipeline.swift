//
//  WakeWordRecognitionPipeline.swift
//  ClickyCore
//
//  P7 wake word: mic (or file) buffers → energy gate → on-device
//  SFSpeechRecognizer → WakeWordMatcher. The same pipeline serves the live
//  listener and the debug inbox's `wakeFeed` (a WAV/CAF fed at real-time
//  pace, no mic, no speaker).
//
//  - Recognition is always on-device (requiresOnDeviceRecognition); a
//    locale without on-device support gets no pipeline at all, never a
//    server fallback. Nothing is written to disk and no transcript leaves
//    this object except through `onEvent`.
//  - CPU: the recognizer only gets audio while the energy gate is open
//    (plus a 0.6 s pre-roll so "hey" isn't clipped). In silence there is no
//    recognition request at all; after the gate closes the request is
//    ended and dropped.
//  - A request is restarted every 50 s (before the ~1 min limit) and after
//    each final result.
//  - A match is reported as a candidate; the owner decides (WakeWordGate:
//    debounce, not while Clicky talks, echo) and calls beginCapture. The
//    turn is then heard on the same request until the hands-free
//    end-of-speech rule (UtteranceEndRule) says it's over.
//  - Everything runs on one serial queue (the recognizer's result handler
//    included); `onEvent` is called on it.
//

import AVFoundation
import Foundation
import Speech

public struct WakeWordCandidate: Equatable, Sendable {
    public let match: WakeWordMatch
    public let requestSerial: Int
    /// Pipeline audio clock (seconds of audio received) when the match was seen.
    public let detectedAtAudioSeconds: TimeInterval
    /// When the phrase ended on the same clock; nil when the recognizer gave no word times.
    public let phraseEndAudioSeconds: TimeInterval?

    /// Phrase end → detection, when the recognizer reported word times.
    public var latencySeconds: TimeInterval? {
        phraseEndAudioSeconds.map { max(0, detectedAtAudioSeconds - $0) }
    }
}

public enum WakeWordPipelineEvent: Sendable {
    case candidate(WakeWordCandidate)
    case captureUpdated(text: String)
    /// The turn after the wake word, finished by the end-of-speech rule (or the 30 s cap).
    case captureFinished(text: String, candidate: WakeWordCandidate)
    /// Nothing was said after the wake word (likely a false wake).
    case captureAbandoned(candidate: WakeWordCandidate)
}

public struct WakeWordPipelineStatistics: Equatable, Sendable {
    public var requestsStarted = 0
    /// Requests restarted at the 50 s limit or after a final result.
    public var restarts = 0
    public var recognizerErrors = 0
    public var gateOpenings = 0
    /// Seconds of audio given to the recognizer (CPU is spent only on these).
    public var recognizedAudioSeconds: TimeInterval = 0
    /// Seconds of audio received in total.
    public var receivedAudioSeconds: TimeInterval = 0
    public var isRequestActive = false
    public var isCapturing = false
    public var usedRecognizerWordTimes = false

    public init() {}
}

public final class WakeWordRecognitionPipeline: @unchecked Sendable {
    public static let requestRestartSeconds: TimeInterval = 50
    public static let preRollSeconds: TimeInterval = 0.6
    /// A capture still running this late in its request is finished (the recognizer stops at ~60 s).
    static let captureRequestAgeLimitSeconds: TimeInterval = 57

    public let localeIdentifier: String
    private let queue = DispatchQueue(label: "clicky.wake.pipeline", qos: .userInitiated)
    private let recognizer: SFSpeechRecognizer
    private let matcher: WakeWordMatcher
    private let onEvent: @Sendable (WakeWordPipelineEvent) -> Void

    // Queue-only state.
    private var gate = EnergyVoiceActivityGate()
    private var preRollBuffers: [(buffer: AVAudioPCMBuffer, startSeconds: TimeInterval, durationSeconds: TimeInterval)] = []
    private var audioClockSeconds: TimeInterval = 0
    private var currentRequest: RequestState?
    /// Requests ended (endAudio) whose final result may still arrive and still count.
    private var endingRequests: [Int: RequestState] = [:]
    private var nextRequestSerial = 1
    /// Clock time each request was opened (for the quick-failure backoff).
    private var requestStartedAudioSeconds: [Int: TimeInterval] = [:]
    private var capture: CaptureState?
    private var isSuppressed = false
    private var statistics = WakeWordPipelineStatistics()
    /// A request that failed right away (assets missing, recognizer busy) isn't retried before this clock time.
    private var retryNotBeforeAudioSeconds: TimeInterval = 0
    static let quickFailureSeconds: TimeInterval = 1
    static let retryDelaySeconds: TimeInterval = 3

    private final class RequestState {
        let serial: Int
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        let startAudioSeconds: TimeInterval
        /// Pipeline clock when each word index was first heard (used when the recognizer has no word times).
        var wordFirstHeardSeconds: [TimeInterval] = []
        /// Segment starts already reported, so one "hey claudia" is one candidate.
        var reportedSegmentStarts: Set<Int> = []
        var latestWords: [WakeTranscriptWord] = []

        init(serial: Int, request: SFSpeechAudioBufferRecognitionRequest, startAudioSeconds: TimeInterval) {
            self.serial = serial
            self.request = request
            self.startAudioSeconds = startAudioSeconds
        }
    }

    private struct CaptureState {
        let candidate: WakeWordCandidate
        let startedAudioSeconds: TimeInterval
        /// The request hearing the turn now (-1 until one starts).
        var requestSerial: Int
        /// Words of the capture's request that belong to the wake phrase (dropped from the turn).
        var droppedWordCount: Int
        /// Turn text from requests that already ended.
        var carriedText: String
        /// Turn text from the current request.
        var currentRequestText = ""
        var lastChangeAudioSeconds: TimeInterval

        var text: String { [carriedText, currentRequestText].filter { !$0.isEmpty }.joined(separator: " ") }
    }

    /// Nil when no recognizer exists for the locale or it can't run on-device.
    public init?(locale: Locale, matcher: WakeWordMatcher, onEvent: @escaping @Sendable (WakeWordPipelineEvent) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else { return nil }
        self.recognizer = recognizer
        self.matcher = matcher
        self.onEvent = onEvent
        self.localeIdentifier = recognizer.locale.identifier
        let resultQueue = OperationQueue()
        resultQueue.underlyingQueue = queue
        resultQueue.maxConcurrentOperationCount = 1
        recognizer.queue = resultQueue
    }

    /// The system locale when it is English and runs on-device, else en-US
    /// when that does, else nil (the wake word stays off).
    public static func preferredLocale(systemLocale: Locale = .autoupdatingCurrent,
                                       supportsOnDevice: (Locale) -> Bool = WakeWordRecognitionPipeline.supportsOnDeviceRecognition) -> Locale? {
        if systemLocale.language.languageCode?.identifier == "en", supportsOnDevice(systemLocale) { return systemLocale }
        let unitedStatesEnglish = Locale(identifier: "en-US")
        return supportsOnDevice(unitedStatesEnglish) ? unitedStatesEnglish : nil
    }

    public static func supportsOnDeviceRecognition(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
    }

    public var isRecognizerAvailable: Bool { recognizer.isAvailable }

    // MARK: - Input (any thread)

    /// Copies the buffer (the tap reuses its memory) and processes it on the queue.
    public func append(_ buffer: AVAudioPCMBuffer) {
        guard let copiedBuffer = Self.copy(buffer) else { return }
        queue.async { self.process(copiedBuffer) }
    }

    /// Clicky is talking: no audio reaches the recognizer (saves CPU; the
    /// owner's gate ignores matches then anyway). A running capture continues.
    public func setSuppressed(_ suppressed: Bool) {
        queue.async {
            guard self.isSuppressed != suppressed else { return }
            self.isSuppressed = suppressed
            if suppressed, self.capture == nil { self.dropAllRequests() }
        }
    }

    /// The owner accepted a candidate: hear the turn after it.
    public func beginCapture(for candidate: WakeWordCandidate) {
        queue.async {
            guard self.capture == nil else { return }
            let isRequestStillOpen = self.currentRequest?.serial == candidate.requestSerial
            self.capture = CaptureState(candidate: candidate, startedAudioSeconds: self.audioClockSeconds,
                                        requestSerial: isRequestStillOpen ? candidate.requestSerial : -1,
                                        droppedWordCount: candidate.match.wordRange.upperBound,
                                        carriedText: isRequestStillOpen ? "" : candidate.match.remainderText,
                                        currentRequestText: isRequestStillOpen ? candidate.match.remainderText : "",
                                        lastChangeAudioSeconds: self.audioClockSeconds)
            self.statistics.isCapturing = true
            if !isRequestStillOpen { self.startRequestIfNeeded(includingPreRoll: false) }
        }
    }

    /// Ends a capture without a turn (push-to-talk took over, Escape…).
    public func cancelCapture() {
        queue.async {
            guard self.capture != nil else { return }
            self.capture = nil
            self.statistics.isCapturing = false
            self.dropAllRequests()
        }
    }

    /// Forget everything (the mic stopped or changed format).
    public func reset() {
        queue.async {
            self.capture = nil
            self.statistics.isCapturing = false
            self.dropAllRequests()
            self.preRollBuffers.removeAll()
            self.gate = EnergyVoiceActivityGate()
        }
    }

    public func currentStatistics() -> WakeWordPipelineStatistics {
        queue.sync { statistics }
    }

    /// Ends the input (file feeds): the open request gets endAudio and the
    /// completion runs once its final result came or after `timeoutSeconds`.
    public func finishInput(timeoutSeconds: TimeInterval, completion: @escaping @Sendable () -> Void) {
        queue.async {
            if let currentRequest = self.currentRequest {
                self.endRequest(currentRequest)
            }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            self.waitForEndingRequests(until: deadline, completion: completion)
        }
    }

    private func waitForEndingRequests(until deadline: Date, completion: @escaping @Sendable () -> Void) {
        if endingRequests.isEmpty || Date() >= deadline {
            completion()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.1) { self.waitForEndingRequests(until: deadline, completion: completion) }
    }

    // MARK: - Audio (queue)

    private func process(_ buffer: AVAudioPCMBuffer) {
        let sampleRate = buffer.format.sampleRate
        guard sampleRate > 0, buffer.frameLength > 0 else { return }
        let durationSeconds = Double(buffer.frameLength) / sampleRate
        let bufferStartSeconds = audioClockSeconds
        audioClockSeconds += durationSeconds
        statistics.receivedAudioSeconds += durationSeconds

        if isSuppressed && capture == nil {
            preRollBuffers.removeAll()
            return
        }

        let gateTransition = gate.process(levelDecibels: Self.levelDecibels(of: buffer), durationSeconds: durationSeconds)
        if gateTransition == .opened { statistics.gateOpenings += 1 }

        if let currentRequest {
            currentRequest.request.append(buffer)
            statistics.recognizedAudioSeconds += durationSeconds
            let requestAgeSeconds = audioClockSeconds - currentRequest.startAudioSeconds
            if capture != nil {
                checkCaptureEnd(requestAgeSeconds: requestAgeSeconds)
            } else if gateTransition == .closed {
                // Quiet again: let the recognizer finish this request, then idle.
                endRequest(currentRequest)
            } else if requestAgeSeconds >= Self.requestRestartSeconds {
                statistics.restarts += 1
                endRequest(currentRequest)
                startRequestIfNeeded(includingPreRoll: false)
            }
            return
        }

        preRollBuffers.append((buffer, bufferStartSeconds, durationSeconds))
        var preRollTotalSeconds = preRollBuffers.reduce(0) { $0 + $1.durationSeconds }
        while preRollTotalSeconds > Self.preRollSeconds, preRollBuffers.count > 1 {
            preRollTotalSeconds -= preRollBuffers.removeFirst().durationSeconds
        }
        if (gate.isOpen || capture != nil) && audioClockSeconds >= retryNotBeforeAudioSeconds {
            startRequestIfNeeded(includingPreRoll: true)
        }
        if capture != nil { checkCaptureEnd(requestAgeSeconds: 0) }
    }

    private func startRequestIfNeeded(includingPreRoll: Bool) {
        guard currentRequest == nil else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        // Nudges the recognizer toward the names it otherwise spells oddly.
        request.contextualStrings = matcher.phraseTexts + matcher.nameWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }

        let startAudioSeconds = includingPreRoll ? (preRollBuffers.first?.startSeconds ?? audioClockSeconds) : audioClockSeconds
        let requestState = RequestState(serial: nextRequestSerial, request: request, startAudioSeconds: startAudioSeconds)
        nextRequestSerial += 1
        if includingPreRoll {
            for preRollBuffer in preRollBuffers {
                request.append(preRollBuffer.buffer)
                statistics.recognizedAudioSeconds += preRollBuffer.durationSeconds
            }
        }
        preRollBuffers.removeAll()

        let requestSerial = requestState.serial
        requestStartedAudioSeconds[requestSerial] = audioClockSeconds
        requestState.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Delivered on `queue` (the recognizer's OperationQueue runs on it).
            self?.handleRecognition(result: result, error: error, requestSerial: requestSerial)
        }
        currentRequest = requestState
        statistics.requestsStarted += 1
        statistics.isRequestActive = true
        if let capture, capture.requestSerial == -1 {
            self.capture?.requestSerial = requestSerial
            self.capture?.droppedWordCount = 0
        }
    }

    /// endAudio: the final result may still carry a wake phrase.
    private func endRequest(_ requestState: RequestState) {
        requestState.request.endAudio()
        endingRequests[requestState.serial] = requestState
        if currentRequest === requestState {
            currentRequest = nil
            statistics.isRequestActive = false
        }
    }

    private func dropAllRequests() {
        for requestState in [currentRequest].compactMap({ $0 }) + Array(endingRequests.values) {
            requestState.task?.cancel()
            requestState.request.endAudio()
        }
        currentRequest = nil
        endingRequests.removeAll()
        requestStartedAudioSeconds.removeAll()
        statistics.isRequestActive = false
    }

    // MARK: - Results (queue)

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, requestSerial: Int) {
        guard let requestState = (currentRequest?.serial == requestSerial ? currentRequest : nil) ?? endingRequests[requestSerial] else { return }

        if let result {
            let words = transcriptWords(from: result.bestTranscription, requestState: requestState)
            requestState.latestWords = words
            if capture?.requestSerial == requestSerial {
                updateCapture(words: words)
            } else if let capture, capture.candidate.requestSerial == requestSerial {
                // The wake request's late final, after the turn moved to a new request.
                updateCarriedTextFromWakeRequest(words: words, capture: capture)
            } else if capture == nil {
                reportCandidateIfAny(words: words, requestState: requestState)
            }
        }

        let isFinished = error != nil || result?.isFinal == true
        guard isFinished else { return }
        if error != nil {
            statistics.recognizerErrors += 1
            // Failing straight away: wait before trying again (no tight retry loop).
            if let startedSeconds = requestStartedAudioSeconds[requestSerial], audioClockSeconds - startedSeconds < Self.quickFailureSeconds {
                retryNotBeforeAudioSeconds = audioClockSeconds + Self.retryDelaySeconds
            }
        }
        requestStartedAudioSeconds[requestSerial] = nil
        endingRequests[requestSerial] = nil
        let wasCurrentRequest = currentRequest?.serial == requestSerial
        if wasCurrentRequest {
            currentRequest = nil
            statistics.isRequestActive = false
        }

        if var capture, capture.requestSerial == requestSerial {
            // The capture's request ended early: keep its words, go on with a fresh one.
            capture.carriedText = capture.text
            capture.currentRequestText = ""
            capture.requestSerial = -1
            capture.droppedWordCount = 0
            self.capture = capture
            // (After a quick failure the next buffer past the backoff starts it instead.)
            if audioClockSeconds >= retryNotBeforeAudioSeconds { startRequestIfNeeded(includingPreRoll: false) }
            return
        }
        // Restart after a final result while there's still sound.
        if wasCurrentRequest, gate.isOpen, !isSuppressed, audioClockSeconds >= retryNotBeforeAudioSeconds {
            statistics.restarts += 1
            startRequestIfNeeded(includingPreRoll: false)
        }
    }

    /// Words with times relative to the request. Uses the recognizer's
    /// segment times when it gives them, else when each word was first heard.
    private func transcriptWords(from transcription: SFTranscription, requestState: RequestState) -> [WakeTranscriptWord] {
        let segments = transcription.segments
        let heardSecondsInRequest = audioClockSeconds - requestState.startAudioSeconds
        while requestState.wordFirstHeardSeconds.count < segments.count {
            requestState.wordFirstHeardSeconds.append(heardSecondsInRequest)
        }
        let hasRecognizerTimes = segments.contains { $0.timestamp > 0 || $0.duration > 0 }
        if hasRecognizerTimes { statistics.usedRecognizerWordTimes = true }
        return segments.enumerated().map { segmentIndex, segment in
            if hasRecognizerTimes {
                return WakeTranscriptWord(text: segment.substring, startSeconds: segment.timestamp, endSeconds: segment.timestamp + segment.duration)
            }
            let firstHeardSeconds = requestState.wordFirstHeardSeconds[segmentIndex]
            return WakeTranscriptWord(text: segment.substring, startSeconds: firstHeardSeconds, endSeconds: firstHeardSeconds)
        }
    }

    private func reportCandidateIfAny(words: [WakeTranscriptWord], requestState: RequestState) {
        guard let match = matcher.firstMatch(in: words), !requestState.reportedSegmentStarts.contains(match.wordRange.lowerBound) else { return }
        requestState.reportedSegmentStarts.insert(match.wordRange.lowerBound)
        let hasWordTimes = words[match.wordRange.upperBound - 1].endSeconds > 0
            && !(words.allSatisfy { $0.startSeconds == $0.endSeconds })
        let candidate = WakeWordCandidate(match: match, requestSerial: requestState.serial, detectedAtAudioSeconds: audioClockSeconds,
                                          phraseEndAudioSeconds: hasWordTimes ? requestState.startAudioSeconds + match.phraseEndSeconds : nil)
        onEvent(.candidate(candidate))
    }

    // MARK: - Capture (queue)

    private func updateCapture(words: [WakeTranscriptWord]) {
        guard var capture else { return }
        let requestText: String
        if capture.requestSerial == capture.candidate.requestSerial, let rematch = matcher.firstMatch(in: words) {
            // Still the wake request: the recognizer may re-spell or re-split the phrase, so find it again.
            requestText = rematch.remainderText
        } else {
            let remainingWords = words.dropFirst(capture.droppedWordCount).map(\.text)
            requestText = WakeWordMatcher.trimmedRemainder(remainingWords.joined(separator: " "))
        }
        guard requestText != capture.currentRequestText else { return }
        capture.currentRequestText = requestText
        capture.lastChangeAudioSeconds = audioClockSeconds
        self.capture = capture
        onEvent(.captureUpdated(text: capture.text))
    }

    /// The request that heard the wake phrase finished after the turn moved
    /// on: its final words after the phrase replace what was carried over.
    private func updateCarriedTextFromWakeRequest(words: [WakeTranscriptWord], capture: CaptureState) {
        guard let finalRemainder = matcher.firstMatch(in: words)?.remainderText,
              finalRemainder.count > capture.carriedText.count else { return }
        var updatedCapture = capture
        updatedCapture.carriedText = finalRemainder
        updatedCapture.lastChangeAudioSeconds = audioClockSeconds
        self.capture = updatedCapture
        onEvent(.captureUpdated(text: updatedCapture.text))
    }

    private func checkCaptureEnd(requestAgeSeconds: TimeInterval) {
        guard let capture else { return }
        let secondsSinceChange = audioClockSeconds - capture.lastChangeAudioSeconds
        let captureSeconds = audioClockSeconds - capture.startedAudioSeconds
        let hasText = !capture.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if UtteranceEndRule.isFinished(heardText: capture.text, secondsSinceLastChange: secondsSinceChange)
            || captureSeconds >= WakeTurnLimits.maximumTurnSeconds
            || requestAgeSeconds >= Self.captureRequestAgeLimitSeconds {
            finishCapture(hasText: hasText)
        } else if !hasText, captureSeconds >= WakeTurnLimits.noSpeechAfterWakeSeconds {
            finishCapture(hasText: false)
        }
    }

    private func finishCapture(hasText: Bool) {
        guard let capture else { return }
        self.capture = nil
        statistics.isCapturing = false
        dropAllRequests()
        if hasText {
            onEvent(.captureFinished(text: capture.text, candidate: capture.candidate))
        } else {
            onEvent(.captureAbandoned(candidate: capture.candidate))
        }
    }

    // MARK: - Buffers

    static func levelDecibels(of buffer: AVAudioPCMBuffer) -> Double {
        // Not float audio: treat as loud so the recognizer still hears it.
        guard let channelData = buffer.floatChannelData else { return 0 }
        return EnergyVoiceActivityGate.rmsDecibels(samples: UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copiedBuffer.frameLength = buffer.frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)
        for (sourceBuffer, destinationBuffer) in zip(sourceBuffers, destinationBuffers) {
            guard let sourceData = sourceBuffer.mData, let destinationData = destinationBuffer.mData else { continue }
            memcpy(destinationData, sourceData, Int(min(sourceBuffer.mDataByteSize, destinationBuffer.mDataByteSize)))
        }
        return copiedBuffer
    }
}

// MARK: - Feeding a file

/// One detection from a file feed, for the debug inbox and tests.
public struct WakeFeedDetection: Equatable, Sendable {
    public let phrase: String
    public let decision: WakeWordGate.Decision
    /// Seconds into the file when the match was seen.
    public let detectedAtSeconds: TimeInterval
    public let phraseEndSeconds: TimeInterval?
    public let latencyMilliseconds: Int?
    /// The words after the phrase once the turn ended (nil if abandoned or not captured).
    public var turnText: String?
}

public struct WakeFeedReport: Sendable {
    public var detections: [WakeFeedDetection] = []
    public var fileSeconds: TimeInterval = 0
    public var statistics = WakeWordPipelineStatistics()
    public var localeIdentifier = ""
    public var errorMessage: String?

    public init() {}
}

public enum WakeWordFileFeeder {
    /// Feeds `fileURL` through a fresh pipeline at real-time pace (so
    /// latency means what it does live), then `trailingSilenceSeconds` of
    /// silence so the turn and the gate can end. Same gate as live, with
    /// Clicky silent. No mic, no speaker, nothing written.
    public static func feed(fileURL: URL, locale: Locale, matcher: WakeWordMatcher, realTime: Bool = true,
                            trailingSilenceSeconds: TimeInterval = 2.5) async -> WakeFeedReport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: feedSynchronously(fileURL: fileURL, locale: locale, matcher: matcher, realTime: realTime,
                                                                 trailingSilenceSeconds: trailingSilenceSeconds))
            }
        }
    }

    private final class FeedCollector: @unchecked Sendable {
        let lock = NSLock()
        var detections: [WakeFeedDetection] = []
        var gate = WakeWordGate()
        weak var pipeline: WakeWordRecognitionPipeline?
    }

    static func feedSynchronously(fileURL: URL, locale: Locale, matcher: WakeWordMatcher, realTime: Bool,
                                  trailingSilenceSeconds: TimeInterval) -> WakeFeedReport {
        var report = WakeFeedReport()
        let collector = FeedCollector()
        guard let pipeline = WakeWordRecognitionPipeline(locale: locale, matcher: matcher, onEvent: { event in
            collector.lock.lock()
            defer { collector.lock.unlock() }
            switch event {
            case .candidate(let candidate):
                let decision = collector.gate.decide(at: Date(), isClickySpeaking: false, lastClickySpeechEndDate: nil,
                                                     recentClickySpokenWords: [], matcher: matcher)
                collector.detections.append(WakeFeedDetection(
                    phrase: candidate.match.phrase, decision: decision, detectedAtSeconds: candidate.detectedAtAudioSeconds,
                    phraseEndSeconds: candidate.phraseEndAudioSeconds,
                    latencyMilliseconds: candidate.latencySeconds.map { Int(($0 * 1000).rounded()) }, turnText: nil))
                if decision == .fire { collector.pipeline?.beginCapture(for: candidate) }
            case .captureFinished(let text, let candidate):
                if let index = collector.detections.lastIndex(where: { $0.detectedAtSeconds == candidate.detectedAtAudioSeconds }) {
                    collector.detections[index].turnText = text
                }
            case .captureUpdated, .captureAbandoned:
                break
            }
        }) else {
            report.errorMessage = "on-device recognition isn't available for \(locale.identifier)"
            return report
        }
        collector.pipeline = pipeline
        report.localeIdentifier = pipeline.localeIdentifier

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            report.errorMessage = "couldn't open \(fileURL.lastPathComponent): \(error.localizedDescription)"
            return report
        }
        let format = audioFile.processingFormat
        let chunkFrameCount = AVAudioFrameCount(max(256, format.sampleRate / 10))
        report.fileSeconds = Double(audioFile.length) / format.sampleRate
        let feedStartDate = Date()
        var fedSeconds: TimeInterval = 0

        func paceAndAppend(_ buffer: AVAudioPCMBuffer) {
            pipeline.append(buffer)
            fedSeconds += Double(buffer.frameLength) / format.sampleRate
            if realTime {
                let aheadSeconds = fedSeconds - Date().timeIntervalSince(feedStartDate)
                if aheadSeconds > 0 { Thread.sleep(forTimeInterval: aheadSeconds) }
            }
        }

        while audioFile.framePosition < audioFile.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) else { break }
            do { try audioFile.read(into: buffer, frameCount: chunkFrameCount) } catch { break }
            if buffer.frameLength == 0 { break }
            paceAndAppend(buffer)
        }
        // Silence (zeros) so the end-of-speech rule and the gate see the pause.
        var silenceLeftSeconds = trailingSilenceSeconds
        while silenceLeftSeconds > 0, let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount) {
            silenceBuffer.frameLength = chunkFrameCount
            let silenceBuffers = UnsafeMutableAudioBufferListPointer(silenceBuffer.mutableAudioBufferList)
            for silenceChannel in silenceBuffers where silenceChannel.mData != nil {
                memset(silenceChannel.mData, 0, Int(silenceChannel.mDataByteSize))
            }
            paceAndAppend(silenceBuffer)
            silenceLeftSeconds -= Double(chunkFrameCount) / format.sampleRate
        }

        let finished = DispatchSemaphore(value: 0)
        pipeline.finishInput(timeoutSeconds: 4) { finished.signal() }
        finished.wait()
        report.statistics = pipeline.currentStatistics()
        collector.lock.lock()
        report.detections = collector.detections
        collector.lock.unlock()
        return report
    }
}
