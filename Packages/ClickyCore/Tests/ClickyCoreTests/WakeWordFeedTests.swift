import AVFoundation
import Foundation
import Speech
import Testing
@testable import ClickyCore

/// P7 wake word, integration style: WAVs made with `say -o` (written to a
/// temp folder, never played) go through the same pipeline the app uses.
///
/// The recognizer part needs Speech Recognition permission for the process
/// running the tests. `swift test` from a terminal normally doesn't have it
/// (and asking would show a system prompt), so those tests are skipped then;
/// the matcher itself is covered by WakeWordTests' transcript fixtures. The
/// app's debug inbox `wakeFeed {path}` runs the same feed inside Clicky,
/// which has the permission.
struct WakeWordFeedTests {
    static let sayExecutableURL = URL(fileURLWithPath: "/usr/bin/say")
    static var canSynthesize: Bool { FileManager.default.isExecutableFile(atPath: sayExecutableURL.path) }
    static var isSpeechRecognitionAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    struct Clip: Sendable {
        let name: String
        let text: String
        let expectedPhrase: String?
        let expectedTurnStart: String?
    }

    static let clips: [Clip] = [
        Clip(name: "claudia-screen", text: "Hey Claudia, what's on my screen?", expectedPhrase: "hey claudia", expectedTurnStart: "what"),
        Clip(name: "clicky-notes", text: "Hey Clicky, open notes.", expectedPhrase: "hey clicky", expectedTurnStart: "open"),
        Clip(name: "neg-claude", text: "Hey Claude, open the file.", expectedPhrase: nil, expectedTurnStart: nil),
        Clip(name: "neg-friend", text: "Claudia is my friend, she lives nearby.", expectedPhrase: nil, expectedTurnStart: nil),
        Clip(name: "neg-chatter", text: "I think we should order pizza tonight and watch a movie.", expectedPhrase: nil, expectedTurnStart: nil)
    ]

    /// Writes `text` as 16-bit 22.05 kHz WAV into `directoryURL` with `say -o` (no playback).
    static func synthesize(_ clip: Clip, into directoryURL: URL) throws -> URL {
        let outputURL = directoryURL.appendingPathComponent("\(clip.name).wav")
        let sayProcess = Process()
        sayProcess.executableURL = sayExecutableURL
        sayProcess.arguments = ["-o", outputURL.path, "--file-format=WAVE", "--data-format=LEI16@22050", clip.text]
        try sayProcess.run()
        sayProcess.waitUntilExit()
        guard sayProcess.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return outputURL
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-wake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// Runs without any permission: the synthesized speech opens the energy
    /// gate once and the trailing silence closes it (what keeps the
    /// recognizer idle between utterances).
    @Test(.enabled(if: WakeWordFeedTests.canSynthesize, "needs /usr/bin/say"))
    func synthesizedSpeechOpensAndClosesTheEnergyGate() throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let clipURL = try Self.synthesize(Self.clips[0], into: directoryURL)
        let audioFile = try AVAudioFile(forReading: clipURL)
        let format = audioFile.processingFormat
        let chunkFrameCount = AVAudioFrameCount(format.sampleRate / 50)
        var gate = EnergyVoiceActivityGate()
        var transitions: [EnergyVoiceActivityGate.Transition] = []
        while audioFile.framePosition < audioFile.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCount))
            try audioFile.read(into: buffer, frameCount: chunkFrameCount)
            if let transition = gate.process(levelDecibels: WakeWordRecognitionPipeline.levelDecibels(of: buffer),
                                             durationSeconds: Double(buffer.frameLength) / format.sampleRate) {
                transitions.append(transition)
            }
        }
        for _ in 0..<100 {
            if let transition = gate.process(levelDecibels: -120, durationSeconds: 0.02) { transitions.append(transition) }
        }
        #expect(transitions.first == .opened)
        #expect(transitions.last == .closed)
    }

    @Test func copiedBuffersKeepTheirSamples() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        for index in 0..<4 { buffer.floatChannelData![0][index] = Float(index) / 4 }
        let copiedBuffer = try #require(WakeWordRecognitionPipeline.copy(buffer))
        buffer.floatChannelData![0][1] = 9
        #expect(copiedBuffer.frameLength == 4)
        #expect(copiedBuffer.floatChannelData![0][1] == 0.25)
        #expect(copiedBuffer.floatChannelData![0][3] == 0.75)
    }

    @Test func preferredLocaleNeverFallsBackToServerRecognition() {
        let englishIndia = Locale(identifier: "en-IN")
        #expect(WakeWordRecognitionPipeline.preferredLocale(systemLocale: englishIndia, supportsOnDevice: { _ in true })?.identifier == "en-IN")
        #expect(WakeWordRecognitionPipeline.preferredLocale(systemLocale: Locale(identifier: "fr-FR"), supportsOnDevice: { _ in true })?.identifier == "en-US")
        #expect(WakeWordRecognitionPipeline.preferredLocale(systemLocale: englishIndia, supportsOnDevice: { $0.identifier == "en-US" })?.identifier == "en-US")
        #expect(WakeWordRecognitionPipeline.preferredLocale(systemLocale: englishIndia, supportsOnDevice: { _ in false }) == nil)
    }

    /// The real recognizer, on-device, through the same path as `wakeFeed`.
    @Test(.enabled(if: WakeWordFeedTests.canSynthesize && WakeWordFeedTests.isSpeechRecognitionAuthorized,
                   "skipped: Speech Recognition isn't authorized for the test runner (asking would show a system prompt). Run the debug inbox's wakeFeed in Clicky instead."),
          .timeLimit(.minutes(2)))
    func synthesizedClipsWakeOnlyOnTheWakePhrase() async throws {
        let directoryURL = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let locale = try #require(WakeWordRecognitionPipeline.preferredLocale())
        for clip in Self.clips {
            let clipURL = try Self.synthesize(clip, into: directoryURL)
            let report = await WakeWordFileFeeder.feed(fileURL: clipURL, locale: locale, matcher: WakeWordMatcher())
            #expect(report.errorMessage == nil, "\(clip.name): \(report.errorMessage ?? "")")
            let firedDetections = report.detections.filter { $0.decision == .fire }
            if let expectedPhrase = clip.expectedPhrase {
                #expect(firedDetections.count == 1, "\(clip.name): \(report.detections)")
                #expect(firedDetections.first?.phrase == expectedPhrase)
                if let expectedTurnStart = clip.expectedTurnStart {
                    #expect(firedDetections.first?.turnText?.lowercased().hasPrefix(expectedTurnStart) == true, "\(clip.name): \(firedDetections)")
                }
            } else {
                #expect(firedDetections.isEmpty, "\(clip.name): \(report.detections)")
            }
        }
    }
}
