//
//  SpeechSelfTests.swift
//  leanring-buddy
//
//  P2 live self-test (debug inbox `selftest`):
//   - qwenCaptionSync: 20 sentences synthesized by Qwen into WAV files (no
//     playback), each transcribed on-device with SFSpeechURLRecognitionRequest;
//     the recognizer's word timestamps are compared with WordTiming's
//     estimates. Passes when p95 |difference| ≤ 250 ms.
//

import ClickyCore
import Foundation
import Speech

@MainActor
enum SpeechSelfTests {
    static let sentences = [
        "Click the Share button in the toolbar, then pick Export as PDF.",
        "Open System Settings and choose Appearance from the sidebar.",
        "The build failed because of a missing semicolon on line forty two.",
        "Press Command-Shift-P, type build, and hit return.",
        "Your downloads folder is in the Finder sidebar, under Favorites.",
        "Drag the slider to the right to make the text bigger.",
        "That error means the server took too long to answer.",
        "First save the file, then close the window and reopen it.",
        "The total for this month is one thousand two hundred eighty four.",
        "Scroll down to the bottom of the page to find the subscribe button.",
        "Switch to list view with the button next to the search field.",
        "The red dot means there are unsaved changes in that tab.",
        "Turn on dark mode, and the whole interface will follow.",
        "This chart shows sales going up every quarter since January.",
        "Select the three rows, then right click and choose delete.",
        "The pull request is waiting for one more approval.",
        "Hold the Option key while you click to see more choices.",
        "Your battery is at forty percent, so plug in soon.",
        "The meeting starts at three thirty in the main room.",
        "Use the gear icon to change how notifications look."
    ]

    static func runQwenCaptionSync(companionManager: CompanionManager) async -> (Bool, [String: Any]) {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else {
            return (false, ["error": "on-device speech recognition isn't available"])
        }
        let client = companionManager.speechOutputClient.qwenLocalVoiceClient
        guard await companionManager.speechOutputClient.qwenServerSupervisor.waitUntilReady(timeoutSeconds: QwenTuning.serverStartupTimeoutSeconds) else {
            return (false, ["error": companionManager.speechOutputClient.qwenServerSupervisor.status])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-qwen-sync", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var differencesMilliseconds: [Double] = []
        var perSentence: [[String: Any]] = []
        for (sentenceIndex, sentence) in sentences.enumerated() {
            do {
                let wavData = try await client.synthesizeSpeech(for: sentence, watchdogSeconds: 30)
                let fileURL = directory.appendingPathComponent("s\(sentenceIndex).wav")
                try wavData.write(to: fileURL)
                guard let audio = PCMAudio(wavData: wavData) else { continue }
                let segment = CaptionParser.parse(sentence, id: sentenceIndex, firstTagIndex: 0)
                let estimates = WordTiming.wordTimes(speech: segment.speech, wordRanges: segment.wordRanges, audio: audio)
                let recognized = try await recognizeWords(fileURL: fileURL, recognizer: recognizer)
                // Match recognized words to sentence words in order (case-insensitive).
                let sentenceWords = segment.wordRanges.map { String(Array(segment.speech)[$0]).lowercased() }
                var searchFrom = 0
                var sentenceDifferences: [Double] = []
                for (word, timestamp) in recognized {
                    guard let matchIndex = sentenceWords[searchFrom...].firstIndex(of: word.lowercased()) else { continue }
                    sentenceDifferences.append(abs(estimates.starts[matchIndex] - timestamp) * 1000)
                    searchFrom = matchIndex + 1
                }
                differencesMilliseconds += sentenceDifferences
                perSentence.append(["index": sentenceIndex, "matched": sentenceDifferences.count, "words": sentenceWords.count,
                                    "maxMs": (sentenceDifferences.max() ?? 0).rounded()])
            } catch {
                perSentence.append(["index": sentenceIndex, "error": String(describing: error)])
            }
        }
        let sorted = differencesMilliseconds.sorted()
        let p95 = sorted.isEmpty ? Double.infinity : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let p50 = sorted.isEmpty ? Double.infinity : sorted[sorted.count / 2]
        return (p95 <= 250, ["p50Ms": p50.rounded(), "p95Ms": p95.rounded(), "words": sorted.count, "sentences": perSentence])
    }

    /// Word start times (seconds) from on-device recognition of a file.
    private static func recognizeWords(fileURL: URL, recognizer: SFSpeechRecognizer) async throws -> [(String, TimeInterval)] {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !hasResumed else { return }
                if let error {
                    hasResumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                hasResumed = true
                continuation.resume(returning: result.bestTranscription.segments.map { ($0.substring, $0.timestamp) })
            }
        }
    }
}
