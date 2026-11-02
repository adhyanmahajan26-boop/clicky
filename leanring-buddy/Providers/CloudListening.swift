//
//  CloudListening.swift
//  leanring-buddy
//
//  Push-to-talk through a cloud service with the owner's key, instead of Apple's on-device recognition: Deepgram,
//  AssemblyAI or Sarvam Saaras. The recorded words go up as one WAV when the keys come up; if the call fails, Clicky
//  uses what Apple's recognizer heard so a turn is never lost. Off unless picked in Settings › Voice.
//

import AVFoundation
import Foundation

enum CloudListening {
    static let settingKey = "v2.listen.engine"

    /// The picked service, when its key is saved.
    static var selected: String? {
        guard let engine = UserDefaults.standard.string(forKey: settingKey), !engine.isEmpty, ProviderKeychain.get(engine) != nil else { return nil }
        return engine
    }

    /// Turns mono 16-bit samples into a WAV file.
    static func wavFile(pcm16: Data, sampleRate: Int) -> Data {
        var wav = Data()
        func text(_ value: String) { wav.append(contentsOf: value.utf8) }
        func little32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        func little16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) } }
        text("RIFF"); little32(36 + pcm16.count); text("WAVEfmt "); little32(16); little16(1); little16(1)
        little32(sampleRate); little32(sampleRate * 2); little16(2); little16(16)
        text("data"); little32(pcm16.count)
        wav.append(pcm16)
        return wav
    }

    /// The transcript from Deepgram's reply.
    static func deepgramTranscript(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [String: Any],
              let channel = (results["channels"] as? [[String: Any]])?.first,
              let alternative = (channel["alternatives"] as? [[String: Any]])?.first else { return nil }
        return alternative["transcript"] as? String
    }

    static func transcribe(wav: Data, engine: String) async throws -> String {
        guard let key = ProviderKeychain.get(engine) else { throw APIChatError.noKey(engine) }
        switch engine {
        case "deepgram":
            guard let url = URL(string: "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true") else { throw APIChatError.rejected("Bad address") }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await URLSession.shared.upload(for: request, from: wav)
            if let failure = ProviderInfo.testFailure(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data) { throw APIChatError.rejected("Deepgram: \(failure)") }
            return deepgramTranscript(data) ?? ""
        case "assemblyai":
            return try await assemblyAI(wav: wav, key: key)
        case "sarvam":
            let result = try await SarvamClient(apiKey: key).transcribe(audio: wav)
            return result.transcript
        default:
            throw APIChatError.rejected("\(engine) can't listen.")
        }
    }

    private static func assemblyAI(wav: Data, key: String) async throws -> String {
        guard let uploadURL = URL(string: "https://api.assemblyai.com/v2/upload"), let createURL = URL(string: "https://api.assemblyai.com/v2/transcript") else { throw APIChatError.rejected("Bad address") }
        var upload = URLRequest(url: uploadURL, timeoutInterval: 30)
        upload.httpMethod = "POST"
        upload.setValue(key, forHTTPHeaderField: "Authorization")
        upload.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (uploadData, uploadResponse) = try await URLSession.shared.upload(for: upload, from: wav)
        if let failure = ProviderInfo.testFailure(statusCode: (uploadResponse as? HTTPURLResponse)?.statusCode ?? 0, body: uploadData) { throw APIChatError.rejected("AssemblyAI: \(failure)") }
        guard let audioURL = (try? JSONSerialization.jsonObject(with: uploadData) as? [String: Any])?["upload_url"] as? String else { throw APIChatError.rejected("AssemblyAI: no upload address") }
        var create = URLRequest(url: createURL, timeoutInterval: 30)
        create.httpMethod = "POST"
        create.setValue(key, forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: ["audio_url": audioURL])
        let (createData, createResponse) = try await URLSession.shared.data(for: create)
        if let failure = ProviderInfo.testFailure(statusCode: (createResponse as? HTTPURLResponse)?.statusCode ?? 0, body: createData) { throw APIChatError.rejected("AssemblyAI: \(failure)") }
        guard let id = (try? JSONSerialization.jsonObject(with: createData) as? [String: Any])?["id"] as? String else { throw APIChatError.rejected("AssemblyAI: no transcript id") }
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let url = URL(string: "https://api.assemblyai.com/v2/transcript/\(id)") else { break }
            var read = URLRequest(url: url, timeoutInterval: 15)
            read.setValue(key, forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: read)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch object?["status"] as? String {
            case "completed": return object?["text"] as? String ?? ""
            case "error": throw APIChatError.rejected("AssemblyAI: \(object?["error"] as? String ?? "failed")")
            default: continue
            }
        }
        throw APIChatError.rejected("AssemblyAI took too long.")
    }
}

/// Collects a microphone tap's audio as mono 16 kHz 16-bit samples. Fed from the audio thread.
final class PushToTalkAudioTape: @unchecked Sendable {
    static let sampleRate = 16000
    private let lock = NSLock()
    private var samples = Data()
    private var converter: AVAudioConverter?
    private let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PushToTalkAudioTape.sampleRate), channels: 1, interleaved: true)

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let output else { return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: output) }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return }
        var supplied = false
        var failure: NSError?
        converter.convert(to: converted, error: &failure) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard failure == nil, let channel = converted.int16ChannelData?[0], converted.frameLength > 0 else { return }
        lock.withLock { samples.append(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))) }
    }

    var wav: Data { lock.withLock { CloudListening.wavFile(pcm16: samples, sampleRate: Self.sampleRate) } }
    var pcm16: Data { lock.withLock { samples } }
    var isEmpty: Bool { lock.withLock { samples.isEmpty } }
}
